// Wires up .btn hover sheen — sets --mx/--my on mousemove for the radial highlight.
// Idempotent; safe to load on any page.
(function () {
  function attach(b) {
    if (b.__sheenAttached) return;
    b.__sheenAttached = true;
    b.addEventListener("mousemove", function (e) {
      var r = b.getBoundingClientRect();
      b.style.setProperty("--mx", (e.clientX - r.left) + "px");
      b.style.setProperty("--my", (e.clientY - r.top) + "px");
    });
  }
  function init() { document.querySelectorAll(".btn").forEach(attach); }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
  // Re-run after dynamic mounts (React etc.) — observe for new .btn nodes
  new MutationObserver(function (muts) {
    muts.forEach(function (m) {
      m.addedNodes.forEach(function (n) {
        if (n.nodeType !== 1) return;
        if (n.classList && n.classList.contains("btn")) attach(n);
        n.querySelectorAll && n.querySelectorAll(".btn").forEach(attach);
      });
    });
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
