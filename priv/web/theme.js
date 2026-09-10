/* Shared by the app, login and phone authorization pages, before first paint. */
(() => {
  const themes = ["dark", "light", "neumorphic", "neumorphic-dark"];
  const labels = { dark: "深色", light: "浅色", neumorphic: "浅色拟物", "neumorphic-dark": "深色拟物" };

  function syncControls(theme) {
    document.querySelectorAll("[data-theme-picker]").forEach(picker => { picker.value = theme; });
    document.querySelectorAll("[data-theme-button]").forEach(button => {
      button.dataset.activeTheme = theme;
      button.title = `界面风格：${labels[theme]}`;
      button.setAttribute("aria-label", `界面风格：${labels[theme]}`);
    });
    document.querySelectorAll("[data-theme-value]").forEach(item => {
      item.setAttribute("aria-checked", item.dataset.themeValue === theme ? "true" : "false");
    });
  }

  function apply(theme, persist = false) {
    if (!themes.includes(theme)) theme = "neumorphic";
    document.documentElement.dataset.theme = theme;
    syncControls(theme);
    if (persist) { try { localStorage.setItem("newbee.theme", theme); } catch (_) {} }
    return theme;
  }

  // 默认是浅色拟物（浅色为底、柔和凸起）；用户显式切换过才用保存值。
  function init() {
    let saved;
    try { saved = localStorage.getItem("newbee.theme"); } catch (_) {}
    return apply(themes.includes(saved) ? saved : "neumorphic");
  }

  function closeMenu(button, menu, restoreFocus = false) {
    menu.classList.add("hidden");
    button.setAttribute("aria-expanded", "false");
    if (restoreFocus) button.focus();
  }

  function placeMenu(button, menu) {
    menu.classList.remove("hidden");
    const buttonRect = button.getBoundingClientRect();
    const menuRect = menu.getBoundingClientRect();
    const gap = 8;
    const left = Math.max(8, Math.min(buttonRect.right - menuRect.width, innerWidth - menuRect.width - 8));
    const below = buttonRect.bottom + gap;
    const top = below + menuRect.height <= innerHeight - 8
      ? below
      : Math.max(8, buttonRect.top - menuRect.height - gap);
    menu.style.left = `${Math.round(left)}px`;
    menu.style.top = `${Math.round(top)}px`;
  }

  function chooseTheme(theme, button, menu) {
    apply(theme, true);
    window.dispatchEvent(new Event("newbee:theme"));
    closeMenu(button, menu, true);
  }

  function bindIconMenu(button) {
    const menu = document.getElementById(button.getAttribute("aria-controls") || "theme-menu");
    if (!menu) return;
    button.setAttribute("aria-controls", menu.id);

    button.addEventListener("click", () => {
      const opening = menu.classList.contains("hidden");
      document.querySelectorAll(".theme-menu:not(.hidden)").forEach(other => {
        if (other !== menu) other.classList.add("hidden");
      });
      if (opening) {
        placeMenu(button, menu);
        button.setAttribute("aria-expanded", "true");
      } else {
        closeMenu(button, menu);
      }
    });

    button.addEventListener("keydown", event => {
      if (!["ArrowDown", "Enter", " "].includes(event.key)) return;
      event.preventDefault();
      if (menu.classList.contains("hidden")) placeMenu(button, menu);
      button.setAttribute("aria-expanded", "true");
      const current = menu.querySelector('[aria-checked="true"]') || menu.querySelector("[data-theme-value]");
      if (current) current.focus();
    });

    const items = [...menu.querySelectorAll("[data-theme-value]")];
    items.forEach(item => item.addEventListener("click", () => chooseTheme(item.dataset.themeValue, button, menu)));
    menu.addEventListener("keydown", event => {
      if (event.key === "Escape") { event.preventDefault(); closeMenu(button, menu, true); return; }
      if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
      event.preventDefault();
      const current = Math.max(0, items.indexOf(document.activeElement));
      const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1
        : (current + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      items[next].focus();
    });

    document.addEventListener("keydown", event => {
      if (event.key === "Escape" && !menu.classList.contains("hidden")) {
        event.preventDefault();
        closeMenu(button, menu, true);
      }
    });
    document.addEventListener("pointerdown", event => {
      if (!menu.classList.contains("hidden") && !menu.contains(event.target) && !button.contains(event.target)) closeMenu(button, menu);
    });
    addEventListener("resize", () => closeMenu(button, menu));
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
    document.querySelectorAll("[data-theme-button]").forEach(bindIconMenu);
  });
})();
