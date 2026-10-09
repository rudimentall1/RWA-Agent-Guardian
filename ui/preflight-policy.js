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

  return Object.freeze({ isPolicyRejection });
});
