// baud's pen: marks drawn by hand over the page, each drawn on as it comes into view, in the
// ink of the section it's on. Declared in the markup, measured from the real layout, redrawn
// (without the drawing) when the layout changes:
//   <span data-pen="under|circle|spark">…</span>   a mark under, around or beside some words
//   <span class="doodle" data-doodle="rack|heart|waves"></span>   a little drawing of its own
//   <i class="note" data-to="selector">…</i>       a handwritten note, an arrow to its target
// Every stroke wobbles the same way on every visit: the wobble is seeded, not random.
(() => {
  const NS = 'http://www.w3.org/2000/svg';
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // A small seeded generator, so a mark is the same mark each time it's drawn.
  const rng = (seed) => () => { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };
  // A smooth line through the points (Catmull-Rom as cubic Béziers).
  const smooth = (p) => {
    let d = `M${p[0][0].toFixed(1)} ${p[0][1].toFixed(1)}`;
    for (let i = 0; i < p.length - 1; i++) {
      const a = p[Math.max(0, i - 1)], b = p[i], c = p[i + 1], e = p[Math.min(p.length - 1, i + 2)];
      d += ` C${(b[0] + (c[0] - a[0]) / 6).toFixed(1)} ${(b[1] + (c[1] - a[1]) / 6).toFixed(1)} ${(c[0] - (e[0] - b[0]) / 6).toFixed(1)} ${(c[1] - (e[1] - b[1]) / 6).toFixed(1)} ${c[0].toFixed(1)} ${c[1].toFixed(1)}`;
    }
    return d;
  };
  // A hand's line from a to b: a few points along it, each nudged off the straight.
  const line = (r, a, b, wob, n = 4) => {
    const p = [];
    for (let i = 0; i <= n; i++) {
      const t = i / n, j = i === 0 || i === n ? wob * 0.4 : wob;
      p.push([a[0] + (b[0] - a[0]) * t + (r() - 0.5) * j, a[1] + (b[1] - a[1]) * t + (r() - 0.5) * j]);
    }
    return smooth(p);
  };
  // A loop around a box that doesn't quite close, the way a pen circles a word.
  const loop = (r, cx, cy, rx, ry) => {
    const p = [], n = 26, start = -1.9 + r() * 0.3, turn = Math.PI * 2 * 1.12;
    for (let i = 0; i <= n; i++) {
      const a = start + (turn * i) / n, k = 1 + (r() - 0.5) * 0.07 + (i / n) * 0.06;
      p.push([cx + Math.cos(a) * rx * k, cy + Math.sin(a) * ry * k]);
    }
    return smooth(p);
  };

  // The marks, in a box w × h (the svg reaches `pad` past it on every side).
  const shapes = {
    under: (r, w, h) => [line(r, [-0.02 * w, h * 0.93], [1.03 * w, h * 0.88], h * 0.06, 5), line(r, [0.14 * w, h * 1.0], [0.86 * w, h * 0.97], h * 0.05, 4)],
    circle: (r, w, h) => [loop(r, w / 2, h / 2, w / 2 + h * 0.45, h * 0.72)],
    spark: (r, w, h) => {
      const x = w + h * 0.12, y = h * 0.1, s = h * 0.22;
      return [line(r, [x, y - s * 0.2], [x + s * 0.5, y - s * 1.1], 2, 2), line(r, [x + s * 0.3, y + s * 0.4], [x + s * 1.3, y + s * 0.1], 2, 2), line(r, [x + s * 0.2, y + s * 1.1], [x + s * 1.1, y + s * 1.5], 2, 2)];
    },
  };
  const doodles = {
    // A data center, as a kid draws one: a rack, its drawers and lights, then a big X through it.
    rack: (r, w, h) => {
      const x0 = w * 0.2, x1 = w * 0.8, y0 = h * 0.12, y1 = h * 0.88, wob = w * 0.02;
      const out = [line(r, [x0, y0], [x1, y0], wob, 3), line(r, [x1, y0], [x1, y1], wob, 3), line(r, [x1, y1], [x0, y1], wob, 3), line(r, [x0, y1], [x0, y0], wob, 3)];
      for (const t of [0.32, 0.54, 0.76]) {
        const y = y0 + (y1 - y0) * t;
        out.push(line(r, [x0, y], [x1, y], wob * 0.6, 3));
        out.push(line(r, [x0 + w * 0.08, y - h * 0.09], [x0 + w * 0.3, y - h * 0.09], wob * 0.4, 2));
        out.push(loop(r, x1 - w * 0.1, y - h * 0.09, w * 0.025, w * 0.025));
      }
      out.push(line(r, [w * 0.04, h * 0.02], [w * 0.98, h * 1.0], wob * 2, 4), line(r, [w * 0.96, h * 0.04], [w * 0.02, h * 0.96], wob * 2, 4));
      return out;
    },
    heart: (r, w, h) => [smooth([[w * 0.5, h * 0.92], [w * 0.14, h * 0.55], [w * 0.1, h * 0.25], [w * 0.3, h * 0.1], [w * 0.5, h * 0.3], [w * 0.7, h * 0.08], [w * 0.92, h * 0.24], [w * 0.86, h * 0.56], [w * 0.52, h * 0.94]].map(([x, y]) => [x + (r() - 0.5) * w * 0.04, y + (r() - 0.5) * h * 0.04]))],
    // Sound, coming off a call: three arcs.
    waves: (r, w, h) => [0.36, 0.66, 0.96].map((k) => smooth([-1, -0.5, 0, 0.5, 1].map((t) => { const a = t * 1.0; return [Math.cos(a) * w * k + (r() - 0.5) * 2, h / 2 + Math.sin(a) * h * 0.5 * k + (r() - 0.5) * 2]; }))),
  };

  const svg = (cls) => { const s = document.createElementNS(NS, 'svg'); s.setAttribute('class', cls); s.setAttribute('aria-hidden', 'true'); return s; };
  const ink = (s, d, width, i, base) => {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d); p.setAttribute('pathLength', '1'); p.style.strokeWidth = width + 'px';
    p.style.transitionDelay = (base + i * 0.16).toFixed(2) + 's';
    s.appendChild(p);
  };
  const place = (s, x, y, w, h) => { Object.assign(s.style, { left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px' }); s.setAttribute('viewBox', `${x} ${y} ${w} ${h}`); };

  function draw(el, n) {
    for (const old of el.querySelectorAll(':scope > svg.pen')) old.remove();
    const r = rng(1000 + n * 7919), w = el.offsetWidth, h = el.offsetHeight, delay = +(el.dataset.delay || 0);
    const fs = parseFloat(getComputedStyle(el).fontSize), width = Math.max(2.5, Math.min(9, fs * 0.055));
    const kind = el.dataset.pen, ds = el.classList.contains('doodle') ? doodles[el.dataset.doodle](r, w, h) : shapes[kind](r, w, h);
    const s = svg('pen'), pad = Math.max(w, h);
    place(s, -pad, -pad, w + pad * 2, h + pad * 2);
    ds.forEach((d, i) => ink(s, d, el.classList.contains('doodle') ? Math.max(2.5, w * 0.022) : width, i, delay));
    el.appendChild(s);
  }

  // A note's arrow: from the note's side nearest its target, bending, to just short of it.
  function arrow(note, n) {
    const host = note.offsetParent; if (!host) return;
    const target = host.querySelector(note.dataset.to) || document.querySelector(note.dataset.to); if (!target) return;
    for (const old of host.querySelectorAll(`:scope > svg.pen[data-for="${n}"]`)) old.remove();
    const hb = host.getBoundingClientRect(), a = note.getBoundingClientRect(), b = target.getBoundingClientRect();
    const box = (q) => ({ l: q.left - hb.left, t: q.top - hb.top, r: q.right - hb.left, b: q.bottom - hb.top, x: (q.left + q.right) / 2 - hb.left, y: (q.top + q.bottom) / 2 - hb.top });
    const A = box(a), B = box(b), gap = 10;
    const dx = B.x - A.x, dy = B.y - A.y, side = Math.abs(dx) > Math.abs(dy) * 1.4;
    const from = side ? [dx > 0 ? A.r + 6 : A.l - 6, A.y] : [A.x, dy > 0 ? A.b + 4 : A.t - 4];
    const to = side ? [dx > 0 ? B.l - gap : B.r + gap, B.y] : [B.x + (note.dataset.nudge ? +note.dataset.nudge : 0), dy > 0 ? B.t - gap : B.b + gap];
    const len = Math.hypot(to[0] - from[0], to[1] - from[1]), bend = (+note.dataset.bend || 0.25) * len;
    const nx = -(to[1] - from[1]) / len, ny = (to[0] - from[0]) / len;
    const mid = [(from[0] + to[0]) / 2 + nx * bend, (from[1] + to[1]) / 2 + ny * bend];
    const r = rng(5000 + n * 104729), wob = 3;
    const p1 = [from, [(from[0] + mid[0]) / 2 + (r() - 0.5) * wob, (from[1] + mid[1]) / 2 + (r() - 0.5) * wob], mid, [(mid[0] + to[0]) / 2 + (r() - 0.5) * wob, (mid[1] + to[1]) / 2 + (r() - 0.5) * wob], to];
    // The head: two short strokes back along the line's last direction.
    const ang = Math.atan2(to[1] - p1[3][1], to[0] - p1[3][0]), hl = 13;
    const head = [-1, 1].map((sg) => line(r, to, [to[0] - Math.cos(ang + sg * 0.5) * hl, to[1] - Math.sin(ang + sg * 0.5) * hl], 1.5, 2));
    const s = svg('pen'); s.dataset.for = n;
    place(s, 0, 0, host.clientWidth, host.clientHeight);
    const delay = +(note.dataset.delay || 0) + 0.25;
    [smooth(p1), ...head].forEach((d, i) => ink(s, d, 3, i, delay));
    if (note.classList.contains('on')) s.classList.add('on');
    host.appendChild(s);
    note._arrow = s;
  }

  // A set font writes every a the same; a hand doesn't. Each letter of a note turned, lifted, sized
  // and weighted a touch differently (seeded, so the same on every visit).
  document.querySelectorAll('.note').forEach((note, n) => {
    const r = rng(7777 + n * 131);
    for (const node of [...note.childNodes]) {
      if (node.nodeType !== 3) continue;
      const frag = document.createDocumentFragment();
      for (const ch of node.textContent) {
        if (ch === ' ') { frag.append(' '); continue; }
        const c = document.createElement('span'); c.className = 'ch'; c.textContent = ch;
        c.style.cssText = `--a:${((r() - 0.5) * 9).toFixed(1)}deg;--y:${((r() - 0.5) * 0.11).toFixed(3)}em;--s:${(1 + (r() - 0.5) * 0.1).toFixed(3)};--w:${Math.round(560 + r() * 170)}`;
        frag.append(c);
      }
      node.replaceWith(frag);
    }
  });
  const marks = [...document.querySelectorAll('[data-pen], .doodle[data-doodle]')];
  const notes = [...document.querySelectorAll('.note[data-to], .note')];
  const all = () => { marks.forEach(draw); notes.forEach((nt, i) => nt.dataset.to && arrow(nt, i)); marks.forEach((m) => m.classList.contains('on') && m.querySelector(':scope > svg.pen')?.classList.add('on')); };
  const show = (el) => {
    el.classList.add('on');
    el.querySelector(':scope > svg.pen')?.classList.add('on');
    el._arrow?.classList.add('on');
  };
  const start = () => {
    all();
    if (still || !('IntersectionObserver' in window)) { [...marks, ...notes].forEach(show); return; }
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { show(e.target); io.unobserve(e.target); } }), { threshold: 0.6 });
    [...marks, ...notes].forEach((el) => io.observe(el));
  };
  // Measured once the fonts are in, so the marks fit the words as set.
  (document.fonts ? document.fonts.ready : Promise.resolve()).then(() => requestAnimationFrame(start));
  let t; addEventListener('resize', () => { clearTimeout(t); t = setTimeout(all, 150); });
})();
