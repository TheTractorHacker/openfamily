(function () {
  "use strict";

  var storageKey = "wb-theme";
  var systemQuery = window.matchMedia("(prefers-color-scheme: dark)");

  function readPreference() {
    try {
      var value = window.localStorage.getItem(storageKey);
      return value === "light" || value === "dark" ? value : "system";
    } catch (error) {
      return "system";
    }
  }

  function resolveTheme(preference) {
    if (preference === "light" || preference === "dark") return preference;
    return systemQuery.matches ? "dark" : "light";
  }

  function applyTheme(preference) {
    var resolved = resolveTheme(preference);
    document.documentElement.dataset.theme = resolved;
    document.documentElement.style.colorScheme = resolved;

    var meta = document.querySelector('meta[name="theme-color"]:not([media])');
    if (!meta) {
      meta = document.createElement("meta");
      meta.name = "theme-color";
      document.head.appendChild(meta);
    }
    meta.content = resolved === "dark" ? "#1c1e22" : "#eef2f6";
    return resolved;
  }

  applyTheme(readPreference());

  document.addEventListener("DOMContentLoaded", function () {
    var body = document.body;
    var header = document.querySelector("[data-header]");
    var nav = document.querySelector("[data-nav]");
    var navToggle = document.querySelector("[data-nav-toggle]");
    var themeToggle = document.querySelector("[data-theme-toggle]");
    var themeText = document.querySelector("[data-theme-text]");
    var themeIcon = document.querySelector("[data-theme-icon]");
    var copyButtons = document.querySelectorAll("[data-copy-command]");
    var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    function syncThemeControl() {
      var resolved = document.documentElement.dataset.theme || resolveTheme(readPreference());
      var next = resolved === "dark" ? "light" : "dark";
      if (themeText) themeText.textContent = next === "dark" ? "Dark" : "Light";
      if (themeIcon) themeIcon.textContent = resolved === "dark" ? "☼" : "◐";
      if (themeToggle) themeToggle.setAttribute("aria-label", "Switch to " + next + " theme");
    }

    syncThemeControl();

    if (themeToggle) {
      themeToggle.addEventListener("click", function () {
        var current = document.documentElement.dataset.theme || "light";
        var next = current === "dark" ? "light" : "dark";
        try { window.localStorage.setItem(storageKey, next); } catch (error) {}
        applyTheme(next);
        syncThemeControl();
      });
    }

    systemQuery.addEventListener("change", function () {
      if (readPreference() === "system") {
        applyTheme("system");
        syncThemeControl();
      }
    });

    function closeMenu() {
      body.classList.remove("nav-open");
      if (navToggle) {
        navToggle.setAttribute("aria-expanded", "false");
        navToggle.setAttribute("aria-label", "Open menu");
      }
    }

    if (navToggle) {
      navToggle.addEventListener("click", function () {
        var open = body.classList.toggle("nav-open");
        navToggle.setAttribute("aria-expanded", String(open));
        navToggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
      });
    }

    if (nav) {
      nav.addEventListener("click", function (event) {
        if (event.target.closest("a")) closeMenu();
      });
    }

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeMenu();
    });

    function syncHeader() {
      if (!header) return;
      var solid = header.hasAttribute("data-header-solid") || window.scrollY > 18;
      header.classList.toggle("is-scrolled", solid);
    }
    syncHeader();
    window.addEventListener("scroll", syncHeader, { passive: true });

    var revealItems = document.querySelectorAll(".reveal:not(.is-visible)");
    if (reducedMotion || !("IntersectionObserver" in window)) {
      revealItems.forEach(function (item) { item.classList.add("is-visible"); });
    } else {
      var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      }, { rootMargin: "0px 0px -8%", threshold: 0.1 });
      revealItems.forEach(function (item) { observer.observe(item); });
    }

    var defaultCommands = [
      "git clone https://github.com/TheTractorHacker/openfamily.git openfamily",
      "cd openfamily",
      "cp .env.example .env",
      "docker compose up -d --build"
    ].join("\n");

    copyButtons.forEach(function (copyButton) {
      copyButton.addEventListener("click", function () {
        var commands = copyButton.getAttribute("data-copy-text") || defaultCommands;
        if (!navigator.clipboard) return;
        navigator.clipboard.writeText(commands).then(function () {
          var original = copyButton.textContent;
          copyButton.textContent = "Copied";
          window.setTimeout(function () { copyButton.textContent = original; }, 1800);
        });
      });
    });

    document.querySelectorAll("[data-year]").forEach(function (element) {
      element.textContent = String(new Date().getFullYear());
    });
  });
})();
