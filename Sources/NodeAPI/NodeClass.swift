@_implementationOnly import CNodeAPI

private typealias ConstructorWrapper = Box<NodeFunction.Callback>

@NodeActor(unsafe) private func cConstructor(rawEnv: napi_env!, info: napi_callback_info!) -> napi_value? {
    NodeContext.withContext(environment: NodeEnvironment(rawEnv)) { ctx -> napi_value in
        let arguments = try NodeArguments(raw: info, in: ctx)
        let data = arguments.data
        let callbacks = Unmanaged<ConstructorWrapper>.fromOpaque(data).takeUnretainedValue()
        return try callbacks.value(arguments).rawValue()
    }
}

extension NodeFunction {

    public convenience init(
        className: String?,
        properties: NodeClassPropertyList,
        constructor: @escaping NodeFunction.VoidCallback
    ) throws {
        var descriptors: [napi_property_descriptor] = []
        var callbacks: [NodeProperty.Callbacks] = []
        for (propName, prop) in properties.elements {
            let nodeProp = prop.nodeProperty
            let (desc, cb) = try nodeProp.raw(name: propName)
            descriptors.append(desc)
            if let cb = cb {
                callbacks.append(cb)
            }
        }
        let ctx = NodeContext.current
        let env = ctx.environment
        var name = className ?? ""
        var result: napi_value!
        let ctorWrapper = ConstructorWrapper { args in
            try constructor(args)
            return undefined
        }
        try name.withUTF8 {
            try $0.withMemoryRebound(to: CChar.self) { nameUTF in
                try env.check(
                    napi_define_class(
                        env.raw,
                        nameUTF.baseAddress,
                        nameUTF.count,
                        cConstructor,
                        Unmanaged.passUnretained(ctorWrapper).toOpaque(),
                        descriptors.count,
                        descriptors,
                        &result
                    )
                )
            }
        }
        self.init(NodeValueBase(raw: result, in: ctx))
        // retain ctor, callbacks
        try addFinalizer {
            _ = ctorWrapper
            _ = callbacks
        }
    }

}

@NodeActor public protocol NodeClass: AnyObject, NodeValueConvertible, NodeValueCreatable where ValueType == NodeObject {
    // mapping from Swift -> JS props
    static var properties: NodeClassPropertyList { get }

    // default implementations provided:
    static var name: String { get }

    // constructor (default implementation throws)
    init(_ arguments: NodeArguments) throws
}

extension NodeClass {
    public init(_ arguments: NodeArguments) throws {
        throw NodeAPIError(
            .genericFailure, 
            message: "Class \(Self.name) is not constructible from JavaScript"
        )
    }
}

enum NodeClassSpecialConstructor<T: NodeClass> {
    case wrap(T)

    func callAsFunction(_ args: NodeArguments) throws -> T {
        switch self {
        case .wrap(let value):
            return value
        }
    }
}

extension NodeClass {
    public static var name: String { "\(self)" }

    private static var classID: ObjectIdentifier {
        .init(self)
    }

    public static func from(_ object: NodeObject) throws -> Self {
        let wrappedValue = try object.wrappedValue(forID: classID)
        guard let value = wrappedValue as? Self else {
            throw NodeAPIError(
                .objectExpected,
                message: "Object of type \(name) is not correctly wrapped"
            )
        }
        return value
    }

    static func from(args: NodeArguments) throws -> Self {
        guard let this = args.this else { 
            throw NodeAPIError(.objectExpected, message: "Function on \(name) called without binding `this`")
        }
        return try this.as(self)
    }

    private static func _constructor() throws -> (NodeFunction, NodeSymbol) {
        let id = classID
        let env = NodeEnvironment.current
        // we memoize this because we don't want to call napi_define_class multiple
        // times
        if let pair = env.instanceData(for: id) as? (NodeFunction, NodeSymbol) {
            return pair
        }
        // this symbol is a special indicator: if we call the constructor with this symbol
        // as the first argument, it indicates a special constructor call. Such a call can
        // only be made by someone who possesses the symbol, and therefore can't be forged
        // from JS
        let sym = try NodeSymbol(description: "Special constructor for NodeSwift class '\(name)'")
        let newCtor = try NodeFunction(className: name, properties: properties) { args in
            guard let this = args.this else { 
                throw NodeAPIError(
                    .objectExpected, 
                    message: "Constructor on \(name) called without binding `this`"
                )
            }
            let value: Self
            if args.count == 2, 
                let argSym = try? args[0].as(NodeSymbol.self),
                sym == argSym {
                    guard let ext = try args[1].as(NodeExternal.self),
                        let special = try ext.value() as? NodeClassSpecialConstructor<Self> else {
                            throw NodeAPIError(
                                .invalidArg, 
                                message: "Invalid call to special constructor of \(name)"
                            )
                        }
                    value = try special(args)
                } else {
                    value = try self.init(args)
                }
            try this.setWrappedValue(value, forID: id)
        }
        let pair = (newCtor, sym)
        env.setInstanceData(pair, for: id)
        return pair
    }

    static func invokeSpecialConstructor(_ specialConstructor: NodeClassSpecialConstructor<Self>) throws -> NodeObject {
        let (ctor, sym) = try Self._constructor()
        return try ctor.new(sym, NodeExternal(value: specialConstructor))
    }

    public static func constructor() throws -> NodeFunction {
        try _constructor().0
    }

    nonisolated public static var deferredConstructor: NodeValueConvertible {
        NodeDeferredValue { try constructor() }
    }

    public func wrapped() throws -> NodeObject {
        try Self.invokeSpecialConstructor(.wrap(self))
    }

    public func nodeValue() throws -> NodeValue {
        try wrapped()
    }
}

extension NodeMethod {
    public init<T: NodeClass>(
        attributes: NodeProperty.Attributes = .defaultMethod,
        _ callback: @escaping (T) -> @NodeActor (NodeArguments) throws -> NodeValueConvertible
    ) {
        self.init(attributes: attributes) { try callback(T.from(args: $0))($0) }
    }
}

extension NodeComputedProperty {
    public init<T: NodeClass>(
        attributes: NodeProperty.Attributes = .defaultProperty,
        get: @escaping (T) -> @NodeActor () throws -> NodeValueConvertible,
        set: ((T) -> @NodeActor (NodeValue) throws -> Void)? = nil
    ) {
        self.init(
            attributes: attributes, 
            get: { try get(T.from(args: $0))() },
            set: set.map { setter in
                { args in
                    guard args.count == 1 else {
                        throw NodeAPIError(.invalidArg, message: "Expected 1 argument to setter, got \(args.count)")
                    }
                    try setter(T.from(args: args))(args[0])
                }
            }
        )
    }

    public init<T: NodeClass, U: NodeValueConvertible>(
        attributes: NodeProperty.Attributes = .defaultProperty,
        get: @escaping (T) -> @NodeActor () throws -> U
    ) {
        self.init(
            attributes: attributes,
            get: { (obj: T) in { try get(obj)().nodeValue() } }
        )
    }

    public init<T: NodeClass, U: NodeValueConvertible & AnyNodeValueCreatable>(
        attributes: NodeProperty.Attributes = .defaultProperty,
        get: @escaping (T) -> @NodeActor () throws -> U,
        set: @escaping (T) -> @NodeActor (U) throws -> Void
    ) {
        self.init(
            attributes: attributes, 
            get: { (obj: T) in { try get(obj)().nodeValue() } },
            set: { (obj: T) in { arg in
                guard let arg = try arg.as(U.self) else {
                    throw NodeAPIError(.invalidArg, message: "Could not convert \(arg) to type \(U.self)")
                }
                try set(obj)(arg)
            } }
        )
    }

    public init<T: NodeClass, U: NodeValueConvertible>(
        attributes: NodeProperty.Attributes = .defaultProperty,
        _ keyPath: KeyPath<T, U>
    ) {
        self.init(attributes: attributes) { (obj: T) in { obj[keyPath: keyPath] } }
    }

    public init<T: NodeClass, U: NodeValueConvertible & AnyNodeValueCreatable>(
        attributes: NodeProperty.Attributes = .defaultProperty,
        _ keyPath: ReferenceWritableKeyPath<T, U>
    ) {
        self.init(attributes: attributes) {
            (cls: T) in { cls[keyPath: keyPath] }
        } set: { (obj: T) in { newValue in
            obj[keyPath: keyPath] = newValue
        } }
    }
}
