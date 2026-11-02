// The light/dark switch: the system's choice until a person picks one; the pick is kept in this
// browser only (hue.js applies it before the first paint). The browser's own bar takes the page's
// ground in either.
(() => {
  const root = document.documentElement;
  const dark = () => root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  const label = (b) => b.setAttribute('aria-label', dark() ? 'Use light mode' : 'Use dark mode');
  const bar = () => { if (window.baud) window.baud.repaint(); };
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', bar);
  for (const b of document.querySelectorAll('.theme')) {
    label(b);
    b.addEventListener('click', () => {
      const t = dark() ? 'light' : 'dark';
      root.dataset.theme = t;
      try { localStorage.setItem('theme', t); } catch (e) {}
      label(b);
      bar();
      document.dispatchEvent(new Event('themechange'));
    });
  }
})();
