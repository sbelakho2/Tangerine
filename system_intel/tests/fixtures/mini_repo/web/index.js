const helper = require("./helper");

function makeApp() {
  return helper.version();
}

class Router {
  handle(req) {
    return makeApp();
  }
}

module.exports = makeApp;
