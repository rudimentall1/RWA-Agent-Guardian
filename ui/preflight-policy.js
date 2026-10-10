(function (root, factory) {
  const policy = factory();
  if (typeof module === "object" && module.exports) module.exports = policy;
  if (root) root.RWA_PREFLIGHT_POLICY = policy;
})(typeof window !== "undefined" ? window : null, function () {
  const POLICY_REJECTIONS = new Set([
    "WrongStatus",
    "InvalidAmount",
    "InvalidAgent",
    "InvalidDeadline",
    "InvalidNonce",
    "AgentLimitExceeded",
    "InsufficientEscrow"
  ]);

  function isPolicyRejection(errorName) {
    return typeof errorName === "string" && POLICY_REJECTIONS.has(errorName);
  }

  function isUnsupportedReadError(error) {
    if (!error || typeof error !== "object" || error.code !== "BAD_DATA") return false;
    const data = error.data ?? error.value ?? error.info?.error?.data;
    const message = String(error.shortMessage ?? error.message ?? "").toLowerCase();
    return data === "0x" || message.includes("could not decode result data");
  }

  return Object.freeze({ isPolicyRejection, isUnsupportedReadError });
});
