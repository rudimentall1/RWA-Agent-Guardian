const test = require("node:test");
const assert = require("node:assert/strict");
const { isPolicyRejection, isUnsupportedReadError } = require("./preflight-policy.js");

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


test("empty BAD_DATA response identifies an unsupported legacy read method", () => {
  assert.equal(isUnsupportedReadError({ code: "BAD_DATA", value: "0x" }), true);
  assert.equal(isUnsupportedReadError({
    code: "BAD_DATA",
    shortMessage: "could not decode result data",
  }), true);
});

test("RPC and timeout failures are not misclassified as unsupported methods", () => {
  for (const error of [
    { code: "NETWORK_ERROR" },
    { code: "TIMEOUT" },
    { code: "SERVER_ERROR", data: "0x" },
    { code: "CALL_EXCEPTION", data: "0x" },
    new Error("connection reset"),
    null,
  ]) {
    assert.equal(isUnsupportedReadError(error), false);
  }
});
