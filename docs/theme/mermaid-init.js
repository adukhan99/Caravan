// Render ```mermaid fences on the published site. GitHub renders the same
// fences natively, so the markdown sources stay portable.
(function () {
  var blocks = document.querySelectorAll("pre > code.language-mermaid");
  if (blocks.length === 0) return;
  var s = document.createElement("script");
  s.src = "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js";
  s.onload = function () {
    blocks.forEach(function (code) {
      var pre = code.parentElement;
      var div = document.createElement("div");
      div.className = "mermaid";
      div.textContent = code.textContent;
      pre.replaceWith(div);
    });
    mermaid.initialize({ startOnLoad: true, theme: "dark" });
  };
  document.head.appendChild(s);
})();
