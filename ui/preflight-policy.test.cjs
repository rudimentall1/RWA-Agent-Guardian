const test = require("node:test");
const assert = require("node:assert/strict");
const { isPolicyRejection } = require("./preflight-policy.js");

test("known on-chain policy rejections are classified as BLOCK", () => {
  for (const name of [
    "WrongStatus",
    "InvalidAmount",
    "InvalidAgent",
    "InvalidDeadline",
    "InvalidNonce",
    "AgentLimitExceeded",
    "InsufficientEscrow"
  ]) {
    assert.equal(isPolicyRejection(name), true, name);
  }
});

test("unknown and infrastructure/configuration errors are not classified as BLOCK", () => {
  for (const name of [
    null,
    undefined,
    "",
    "Unauthorized",
    "InvalidInvoice",
    "TransferFailed",
    "Reentrancy",
    "CALL_EXCEPTION",
    "NETWORK_ERROR",
    "UnknownCustomError"
  ]) {
    assert.equal(isPolicyRejection(name), false, String(name));
  }
});
