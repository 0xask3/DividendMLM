const Token = artifacts.require("Hyip");

module.exports = async function (deployer, network, accounts) {
  await deployer.deploy(Token,accounts[1],accounts[2]);
};
