const { nums, str, add } = require("../.build/Module.node");

class Index {

    test(){
        console.log(nums); // [ 3, 4 ]
        console.log(str); // NodeSwift! NodeSwift! NodeSwift!
        add(5, 10).then(console.log); // 5.0 + 10.0 = 15.0
    }
}
((function(){
    let index = new Index();
    index.test();
})())
exports = Index;
