/* Shared by the app, login and phone authorization pages, before first paint. */
(() => {
  const themes = ["dark", "light", "neumorphic", "neumorphic-dark"];
  function apply(theme, persist = false) {
    if (!themes.includes(theme)) theme = "dark";
    document.documentElement.dataset.theme = theme;
    document.querySelectorAll("[data-theme-picker]").forEach(picker => { picker.value = theme; });
    if (persist) { try { localStorage.setItem("newbee.theme", theme); } catch (_) {} }
    return theme;
  }
  function init() {
    let saved;
    try { saved = localStorage.getItem("newbee.theme"); } catch (_) {}
    const system = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    return apply(themes.includes(saved) ? saved : system);
  }
  window.NewbeeTheme = { apply, init };
  init();
  document.addEventListener("DOMContentLoaded", () => {
    apply(document.documentElement.dataset.theme);
    document.querySelectorAll("[data-theme-picker]").forEach(picker => {
      picker.addEventListener("change", () => {
        apply(picker.value, true);
        window.dispatchEvent(new Event("newbee:theme"));
      });
    });
  });
})();
