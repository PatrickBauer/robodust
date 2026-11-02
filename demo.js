// A pocket version of the RoboDust app: same behaviours, pretend files, all on one canvas.
(() => {
  const canvas = document.getElementById('floor');
  const ctx = canvas.getContext('2d');
  const stage = document.getElementById('stage');
  const statusEl = document.getElementById('status');
  const countEl = document.getElementById('count');
  const ledEl = document.getElementById('led');
  const actionsEl = document.getElementById('hudActions');
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

  const R = 56, ICON = 46, LABEL_W = 92, LABEL_H = 28;
  const rand = (a = 0, b = 1) => a + (b - a) * Math.random();
  const clamp = (v, a, b) => Math.min(Math.max(v, a), b);
  const wrap = a => { while (a > Math.PI) a -= 2 * Math.PI; while (a < -Math.PI) a += 2 * Math.PI; return a; };
  const smooth = t => t * t * (3 - 2 * t);
  const len = (x, y) => Math.hypot(x, y);

  let W = 960, H = 600, scale = 1, dpr = 1;
  let floorLayer, dustLayer, laneLayer;
  let mode = 'trash';

  const images = {};
  for (const [k, src] of [['robot', 'assets/robot-sheet.jpg'], ['dockEmpty', 'assets/dock-empty.png'], ['dockFull', 'assets/dock-full.png']]) {
    images[k] = new Image(); images[k].src = src;
  }

  const FILES = [
    ['final-final-v2.pdf', 'doc', 2], ['Screenshot 2026-10-12.png', 'shot', 1], ['Screenshot 2026-10-14.png', 'shot', 1],
    ['weekend-take-12.mov', 'video', 6], ['backup-of-the-backup.zip', 'zip', 6], ['do-not-delete', 'folder', 3],
    ['to-delete-later', 'folder', 2], ['blurry-pigeon.heic', 'photo', 2], ['notes copy 2.txt', 'doc', 1],
    ['logo-new-NEW.png', 'photo', 1], ['meeting-that-could-be-an-email.txt', 'doc', 1], ['Screenshot 2026-10-21.png', 'shot', 1],
    ['misc', 'folder', 2], ['misc 2', 'folder', 2], ['Untitled.txt', 'doc', 1], ['three-dollar-song.m4a', 'audio', 2],
    ['IMG_2041.jpeg', 'photo', 2], ['resume_v14.pdf', 'doc', 1], ['taxes-2023.zip', 'zip', 3], ['Screenshot 2026-10-28.png', 'shot', 1],
    ['demo-for-nobody.mp4', 'video', 4], ['mood-board.png', 'photo', 2],
  ];

  const offscreen = (w, h) => {
    const c = document.createElement('canvas');
    c.width = Math.ceil(w * dpr); c.height = Math.ceil(h * dpr);
    const g = c.getContext('2d'); g.scale(dpr, dpr);
    return [c, g];
  };
  const rr = (g, x, y, w, h, r) => { g.beginPath(); g.roundRect(x, y, w, h, r); };

  function iconSprite(kind, seed) {
    const [c, g] = offscreen(ICON, ICON);
    const s = ICON;
    g.shadowColor = 'rgba(40,25,5,.35)'; g.shadowBlur = 3; g.shadowOffsetY = 1.5;
    if (kind === 'folder') {
      g.fillStyle = '#3f9de6'; rr(g, s * .08, s * .17, s * .4, s * .22, 3); g.fill();
      g.shadowColor = 'transparent';
      const f = g.createLinearGradient(0, s * .25, 0, s * .85); f.addColorStop(0, '#74c4f8'); f.addColorStop(1, '#4aa7ee');
      g.fillStyle = f; rr(g, s * .06, s * .25, s * .88, s * .6, 4); g.fill();
    } else if (kind === 'photo' || kind === 'shot') {
      const w = kind === 'shot' ? s * .9 : s * .78, h = kind === 'shot' ? s * .62 : s * .68;
      const x = (s - w) / 2, y = (s - h) / 2;
      g.fillStyle = '#fff'; g.fillRect(x, y, w, h); g.shadowColor = 'transparent';
      if (kind === 'photo') {
        const hue = (seed * 67) % 360;
        const f = g.createLinearGradient(x, y, x + w, y + h);
        f.addColorStop(0, `hsl(${hue} 70% 62%)`); f.addColorStop(1, `hsl(${(hue + 60) % 360} 60% 45%)`);
        g.fillStyle = f; g.fillRect(x + 2.5, y + 2.5, w - 5, h - 5);
        g.fillStyle = 'rgba(255,255,255,.45)'; g.beginPath(); g.arc(x + w * .68, y + h * .36, s * .08, 0, 7); g.fill();
      } else {
        g.fillStyle = '#e8e8e6'; g.fillRect(x + 2, y + 2, w - 4, 5);
        g.fillStyle = '#c9c9c6'; for (let i = 0; i < 4; i++) g.fillRect(x + 5, y + 11 + i * 5, w * (.4 + .4 * ((seed * (i + 3)) % 5) / 5), 2);
      }
    } else {
      const x = s * .17, y = s * .06, w = s * .66, h = s * .88, fold = s * .19;
      g.fillStyle = '#fff'; g.beginPath(); g.moveTo(x + 3, y); g.lineTo(x + w - fold, y); g.lineTo(x + w, y + fold); g.lineTo(x + w, y + h - 3);
      g.quadraticCurveTo(x + w, y + h, x + w - 3, y + h); g.lineTo(x + 3, y + h); g.quadraticCurveTo(x, y + h, x, y + h - 3); g.lineTo(x, y + 3); g.quadraticCurveTo(x, y, x + 3, y); g.fill();
      g.shadowColor = 'transparent';
      g.fillStyle = '#dcdcd9'; g.beginPath(); g.moveTo(x + w - fold, y); g.lineTo(x + w, y + fold); g.lineTo(x + w - fold, y + fold); g.fill();
      if (kind === 'doc') { g.fillStyle = '#c2c2bf'; for (let i = 0; i < 6; i++) g.fillRect(x + 5, y + 14 + i * 4.4, (w - 10) * (i === 5 ? .55 : 1), 1.7); }
      else {
        const tag = { zip: 'ZIP', video: 'MOV', audio: 'M4A' }[kind];
        if (kind === 'zip') { g.fillStyle = '#b8b8b5'; for (let i = 0; i < 6; i++) g.fillRect(x + w / 2 - 2 + (i % 2 ? 2 : -2), y + 2 + i * 4, 4, 2.4); }
        if (kind === 'video') { g.fillStyle = '#a0a09d'; g.beginPath(); g.moveTo(x + w * .36, y + h * .32); g.lineTo(x + w * .68, y + h * .47); g.lineTo(x + w * .36, y + h * .62); g.fill(); }
        if (kind === 'audio') { g.fillStyle = '#a0a09d'; [8, 14, 9, 16, 7].forEach((l, i) => g.fillRect(x + w * .24 + i * 4.2, y + h * .46 - l / 2, 2, l)); }
        g.fillStyle = '#9a9a97'; g.font = '600 7px Inter, system-ui, sans-serif'; g.textAlign = 'center'; g.fillText(tag, x + w / 2, y + h - 5);
      }
    }
    return c;
  }

  function labelSprite(name) {
    const [c, g] = offscreen(LABEL_W, LABEL_H);
    g.font = '500 10.5px Inter, system-ui, sans-serif'; g.textAlign = 'center'; g.fillStyle = '#2b1c0c';
    const max = LABEL_W - 4;
    const lines = [];
    let rest = name;
    if (g.measureText(rest).width > max) {
      let cut = rest.length;
      while (cut > 1 && g.measureText(rest.slice(0, cut)).width > max) cut--;
      const brk = Math.max(rest.lastIndexOf(' ', cut), rest.lastIndexOf('-', cut));
      if (brk > cut / 3) cut = brk + 1;
      lines.push(rest.slice(0, cut).trim()); rest = rest.slice(cut);
      if (g.measureText(rest).width > max) {
        let keep = rest.length;
        const fit = k => rest.slice(0, k >> 1) + '…' + rest.slice(rest.length - (k - (k >> 1)));
        while (keep > 2 && g.measureText(fit(keep)).width > max) keep--;
        rest = fit(keep);
      }
    }
    lines.push(rest);
    lines.forEach((l, i) => g.fillText(l, LABEL_W / 2, 11 + i * 12.5));
    return c;
  }

  // ---------- world ----------
  let items = [], parts = [];
  const robot = { x: 0, y: 0, a: -Math.PI / 2, v: 0, w: 0, brush: 0, brushV: 0, bump: 0, shake: 0, lift: 0, picked: false, drop: 0 };
  let dock = { x: 0, y: 0 };
  let phase = 'ready', phaseT = 0, sweep = 0, path = [], pathI = 0, wpT = 0, heavy = 0, bagFill = 0, emptied = 0, collected = 0;
  let huntTarget = null, huntT = 0, maneuver = null, lastBump = -9, dockAligned = false, t = 0;
  let mouse = null, grabbed = null, dragV = [0, 0], lastDrag = [0, 0], started = false, flash = 0;

  const fx = () => Math.cos(robot.a), fy = () => Math.sin(robot.a);
  const intake = () => ({ x: robot.x + fx() * R * .8, y: robot.y + fy() * R * .8 });
  const brushes = () => {
    const ax = fx() * R * .62, ay = fy() * R * .62, sx = -fy() * R * .72, sy = fx() * R * .72;
    return [[robot.x + ax + sx, robot.y + ay + sy, -1], [robot.x + ax - sx, robot.y + ay - sy, 1]];
  };

  function layout() {
    const rect = stage.getBoundingClientRect();
    if (rect.width < 10 || rect.height < 10) return false;
    dpr = Math.min(devicePixelRatio || 1, 2);
    scale = clamp(rect.width / 960, .62, 1.1);
    W = rect.width / scale; H = rect.height / scale;
    canvas.width = Math.round(rect.width * dpr); canvas.height = Math.round(rect.height * dpr);
    dock = { x: W * .8, y: H - R * 2.1 - 8 };
    buildFloor();
    return true;
  }

  function buildFloor() {
    let g;
    [floorLayer, g] = offscreen(W, H);
    const plankH = 62;
    let seedRand = mulberry(7);
    for (let y = -10, row = 0; y < H; y += plankH, row++) {
      for (let x = -seedRand() * 200; x < W;) {
        const w = 210 + seedRand() * 150, d = (seedRand() - .5) * 8;
        g.fillStyle = `rgb(${232 + d},${204 + d},${160 + d})`; g.fillRect(x, y, w, plankH);
        for (let i = 0; i < 6; i++) {
          g.strokeStyle = `rgba(130,90,45,${.03 + seedRand() * .05})`; g.lineWidth = .5 + seedRand() * .6;
          const gy = y + 4 + seedRand() * (plankH - 8);
          g.beginPath(); g.moveTo(x, gy); g.bezierCurveTo(x + w * .3, gy + (seedRand() - .5) * 8, x + w * .7, gy + (seedRand() - .5) * 8, x + w, gy + (seedRand() - .5) * 6); g.stroke();
        }
        g.fillStyle = 'rgba(100,68,35,.3)'; g.fillRect(x + w - .6, y, .6, plankH);
        x += w;
      }
      g.fillStyle = 'rgba(100,68,35,.3)'; g.fillRect(0, y + plankH - .6, W, .6);
    }
    resetDust();
  }
  function mulberry(a) { return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }

  function resetDust() {
    let g;
    [dustLayer, g] = offscreen(W, H);
    const count = Math.round(W * H / 620);
    for (let i = 0; i < count; i++) {
      g.fillStyle = `rgba(80,68,55,${rand(.16, .45)})`;
      const d = rand(.5, 1.5); g.beginPath(); g.arc(rand(0, W), rand(0, H), d, 0, 7); g.fill();
    }
    [laneLayer] = offscreen(W, H);
  }

  function makeItems() {
    const spec = W < 620 ? FILES.slice(0, 11) : FILES.slice(0, 16);
    const placed = [];
    items = spec.map(([name, kind, mass], i) => {
      let x = 0, y = 0, tries = 0, best = -1, bx = 0, by = 0;
      do {
        x = rand(46, W - 46); y = rand(44, H - 110);
        const nearest = Math.min(1e9, ...placed.map(p => len(p[0] - x, p[1] - y)));
        const clearDock = Math.abs(x - dock.x) > R * 2.1 || y < dock.y - R * 2.6;
        if (clearDock && nearest > best) { best = nearest; bx = x; by = y; }
      } while (++tries < 24);
      x = bx; y = by; placed.push([x, y]);
      return {
        i, name, kind, mass, homeX: x, homeY: y, x, y, vx: 0, vy: 0, a: rand(-.06, .06), av: 0, agit: 0, pull: 0, eating: false, gone: false,
        ping: 0, seed: i * 1.618, icon: iconSprite(kind, i + 2), lab: labelSprite(name),
        label: { x, y: y + 37, vx: 0, vy: 0, a: 0, av: 0, agit: 0, pull: 0, eating: false, gone: false, on: true, seed: i * 2.4 },
        fly: null, inBin: false, inBag: false, scale: 1, grabbed: false,
      };
    });
  }

  function setPhase(p) { phase = p; phaseT = 0; }
  function setStatus(s, led) {
    if (statusEl.textContent !== s) statusEl.textContent = s;
    const cls = 'led ' + (led || '');
    if (ledEl.className !== cls) ledEl.className = cls;
    const remaining = items.length;
    const c = ['clean', 'hunt', 'return', 'dock', 'empty'].includes(phase) ? `${collected} of ${remaining}` : '';
    if (countEl.textContent !== c) countEl.textContent = c;
  }

  function button(label, kind, fn) {
    const b = document.createElement('button');
    b.className = 'hud-btn ' + kind; b.textContent = label; b.addEventListener('click', fn);
    return b;
  }
  function showActions(list) {
    actionsEl.replaceChildren(...list);
    actionsEl.hidden = list.length === 0;
  }

  // ---------- flow ----------
  function restart() {
    resetDust(); makeItems();
    Object.assign(robot, { x: dock.x, y: dock.y, a: -Math.PI / 2, v: 0, w: 0, bump: 0, picked: false, lift: 0 });
    bagFill = 0; collected = 0; emptied = 0; sweep = 0; parts = []; huntTarget = null; maneuver = null; dockAligned = false;
    robot.drop = 0;
    showActions([]);
    setPhase('drop');
  }

  function planLanes() {
    const live = items.filter(onFloor).map(it => [it.x, it.y]);
    path = []; pathI = 0; wpT = 0;
    if (!live.length) return;
    const step = R * 2;
    const ys = live.map(p => p[1]);
    const minY = Math.max(Math.min(...ys), R + 3), maxY = Math.min(Math.max(...ys), H - R - 3);
    const lanes = [];
    for (let y = minY; y <= maxY + step * .5; y += step) {
      const yy = Math.min(y, maxY);
      const band = live.filter(p => Math.abs(p[1] - yy) < step * .62).map(p => p[0]);
      if (band.length) lanes.push([yy, Math.min(...band) - R * .5, Math.max(...band) + R * .5]);
    }
    if (Math.abs(lanes[0][0] - robot.y) > Math.abs(lanes[lanes.length - 1][0] - robot.y)) lanes.reverse();
    let x = robot.x;
    for (const [y, a, b] of lanes) {
      const near = Math.abs(a - x) < Math.abs(b - x) ? a : b, far = near === a ? b : a;
      for (const px of [near, far]) { const q = walkClamp(px, y); if (!keepOut(q[0], q[1])) path.push(q); }
      x = far;
    }
  }
  const walkClamp = (x, y) => [clamp(x, R + 2, W - R - 2), clamp(y, R + 2, H - R - 2)];
  const keepOut = (x, y) => (dock.y - y) < R * 2 && Math.abs(x - dock.x) < R * 2.3;
  const onFloor = it => !it.inBin && !it.inBag && !it.fly && !it.gone;
  const remaining = () => items.filter(it => !it.gone && !it.inBin && !it.inBag).length;

  function drive(v, w, dt) {
    robot.v += clamp(v - robot.v, -900 * dt, 900 * dt);
    robot.w += clamp(w - robot.w, -12 * dt, 12 * dt);
  }

  function follow(dt) {
    if (pathI >= path.length) { drive(0, 0, dt); return; }
    if (maneuver) {
      drive(maneuver.back > 0 ? -80 : 0, maneuver.back > 0 ? 0 : maneuver.dir * 2.6, dt);
      if (maneuver.back > 0) maneuver.back -= dt; else maneuver.turn -= dt;
      if (maneuver.turn <= 0) maneuver = null;
      return;
    }
    if (mouse) {
      const dx = mouse.x - robot.x, dy = mouse.y - robot.y;
      if (len(dx, dy) < R + 14 && dx * fx() + dy * fy() > 0 && t - lastBump > 1.2) {
        lastBump = t; robot.bump = 1; flash = 1.1;
        maneuver = { back: .32, turn: .45, dir: (dx * -fy() + dy * fx()) > 0 ? -1 : 1 };
        return;
      }
    }
    let [tx, ty] = path[pathI];
    wpT += dt;
    const reach = pathI === path.length - 1 ? R * .3 : R * .45;
    if (len(tx - robot.x, ty - robot.y) < reach || wpT > 12) {
      pathI++; wpT = 0;
      if (pathI >= path.length) return;
      [tx, ty] = path[pathI];
    }
    let ax = tx, ay = ty;
    const d = len(tx - robot.x, ty - robot.y);
    if (pathI + 1 < path.length && d < R * 1.4) {
      const [nx, ny] = path[pathI + 1], k = 1 - d / (R * 1.4), l = Math.max(len(nx - tx, ny - ty), 1);
      ax += (nx - tx) / l * R * .9 * k; ay += (ny - ty) / l * R * .9 * k;
    }
    const err = wrap(Math.atan2(ay - robot.y, ax - robot.x) - robot.a);
    const align = clamp(1 - Math.abs(err) / 1.15, 0, 1);
    let v = 560 * align * align;
    const eating = items.filter(it => it.eating).length;
    if (eating) v *= Math.max(.55, 1 - .14 * eating);
    v *= 1 - .7 * clamp(heavy, 0, 1);
    if (pathI === path.length - 1) v = Math.min(v, Math.max(60, d * 2.2));
    drive(v, clamp(err * 4.2, -3.1, 3.1), dt);
  }

  function goDock() { path = [[dock.x, dock.y - R * 3]]; pathI = 0; wpT = 0; setPhase('return'); }

  function chip(x, y, dx, dy, color) {
    if (parts.length > 400) parts.shift();
    parts.push({ x, y, vx: dx, vy: dy, life: rand(.2, .5), max: .5, size: rand(1.5, 3.4), color, a: rand(0, 6) });
  }

  function startEat(it, target) {
    if (target.eating) return;
    target.eating = true; target.pull = .001;
    if (target === it) {
      if (it.label.on) detach(it);
      const c = { folder: '#5bb2f2', photo: '#e98a6a', shot: '#fff', doc: '#fff', zip: '#ddd', video: '#ddd', audio: '#ddd' }[it.kind];
      const p = intake();
      for (let i = 0; i < 5 + it.mass * 2; i++) {
        const dir = Math.atan2(p.y - it.y, p.x - it.x) + rand(-1.2, 1.2), sp = rand(50, 190);
        chip(it.x + rand(-16, 16), it.y + rand(-16, 16), Math.cos(dir) * sp, Math.sin(dir) * sp, c);
      }
    }
  }
  function detach(it) {
    const l = it.label; l.on = false;
    l.x = it.x - Math.sin(it.a) * 37; l.y = it.y + Math.cos(it.a) * 37; l.vx = it.vx; l.vy = it.vy; l.a = it.a; l.av = rand(-5, 5);
  }

  function field(b, mass, on, dt) {
    const rx = b.x - robot.x, ry = b.y - robot.y;
    const f = rx * fx() + ry * fy(), s = rx * -fy() + ry * fx();
    const p = intake(), tx = p.x - b.x, ty = p.y - b.y, d = len(tx, ty) || 1;
    if (on) {
      const reach = R * 2.5;
      if (d < reach) {
        const k = 1 - d / reach, front = smooth(clamp((f + R * .3) / (R * .8), 0, 1));
        const acc = 2100 * k * k * (.2 + .8 * front) / mass;
        b.vx += tx / d * acc * dt; b.vy += ty / d * acc * dt;
        b.agit = Math.max(b.agit, k * front * 1.15);
      }
      for (const [cx, cy, sign] of brushes()) {
        const ex = b.x - cx, ey = b.y - cy, el = len(ex, ey) || 1, br = R * .62;
        if (el < br) {
          const k = 1 - el / br;
          b.vx += ((-ey / el) * sign * 820 + tx / d * 500) * k * dt / mass;
          b.vy += ((ex / el) * sign * 820 + ty / d * 500) * k * dt / mass;
          b.av += sign * 50 * k * dt / mass;
          b.agit = Math.max(b.agit, .5 + k * .5);
        }
      }
    }
    if (!robot.picked) {
      const l = len(rx, ry) || 1, keep = R + 11;
      if (on && f > R * .1 && Math.abs(s) < R * .98 && l < R + 28) return true;
      if (l < keep) {
        const nx = rx / l, ny = ry / l;
        b.x = robot.x + nx * keep; b.y = robot.y + ny * keep;
        const vr = robot.v * (fx() * nx + fy() * ny);
        if (vr > 0) { b.vx += nx * vr * 1.1; b.vy += ny * vr * 1.1; }
        b.agit = Math.max(b.agit, .5);
      }
    }
    return false;
  }
  function settle(b, dt, damp) {
    b.x += b.vx * dt; b.y += b.vy * dt;
    const k = Math.exp(-dt * damp); b.vx *= k; b.vy *= k;
    b.a += b.av * dt; b.av *= Math.exp(-dt * 3.2);
    b.a += -b.a * (1 - Math.exp(-dt * .6 * (1 - b.agit)));
    b.agit = Math.max(0, b.agit - dt * 1.7);
    b.x = clamp(b.x, 22, W - 22); b.y = clamp(b.y, 22, H - 22);
    const u = dock.y - b.y;
    if (u < R * 1 && u > -R * 2.3 && Math.abs(b.x - dock.x) < R * 1.45) { b.y = dock.y - R; b.vy -= 40; }
  }
  function eat(b, dur, dt) {
    const p = intake();
    b.pull = Math.min(1, b.pull + dt / dur);
    const k = 1 - Math.exp(-dt * (2.5 + 9 * b.pull * b.pull));
    b.x += (p.x - b.x) * k; b.y += (p.y - b.y) * k; b.agit = 1; b.a += b.av * dt;
    if (b.pull >= 1) { b.gone = true; b.eating = false; }
  }

  function updateItems(dt) {
    const on = ['clean', 'hunt'].includes(phase);
    for (const it of items) {
      it.ping = Math.max(0, it.ping - dt * 1.3);
      if (it.fly) { flight(it, dt); continue; }
      if (it.inBin || it.inBag) continue;
      if (!it.gone) {
        if (it.grabbed) it.agit = Math.max(it.agit, .25);
        else if (it.eating) {
          eat(it, .26 + .17 * (it.mass - 1), dt);
          heavy = Math.max(heavy, clamp((it.mass - 3.5) / 2.5, 0, 1));
          if (it.mass > 3) robot.shake = Math.max(robot.shake, .2 * it.mass / 6);
          if (it.gone) { it.inBin = true; collected++; }
        } else {
          if (field(it, it.mass * .75 + .5, on, dt)) startEat(it, it);
          settle(it, dt, 5.5);
        }
      }
      const l = it.label;
      if (l.on && it.agit > .62 + .25 * Math.sin(it.seed * 13)) detach(it);
      if (!l.on && !l.gone) {
        if (l.eating) eat(l, .28, dt);
        else {
          if (field(l, .32, on, dt)) startEat(it, l);
          if (it.gone) {
            l.lost = (l.lost || 0) + dt;
            if (l.lost > .8) startEat(it, l);
          }
          settle(l, dt, 3.6);
          l.vx += Math.sin(t * 7 + l.seed) * 40 * l.agit * dt; l.vy += Math.cos(t * 5.3 + l.seed) * 40 * l.agit * dt;
        }
      }
    }
    const awake = items.filter(it => it.agit > .02 && !it.eating && !it.grabbed && onFloor(it));
    for (let i = 0; i < awake.length; i++) for (let j = i + 1; j < awake.length; j++) {
      const a = awake[i], b = awake[j], dx = b.x - a.x, dy = b.y - a.y, l = len(dx, dy);
      if (l < 40 && l > .01) { const p = (40 - l) * 7 * dt; a.x -= dx / l * p / a.mass; a.y -= dy / l * p / a.mass; b.x += dx / l * p / b.mass; b.y += dy / l * p / b.mass; }
    }
  }

  const bag = () => ({ x: dock.x, y: dock.y + R * 1.5 });

  function launch(it, fx0, fy0, tx, ty, delay, kind) {
    it.fly = { fx: fx0, fy: fy0, tx, ty, t: 0, delay, dur: kind === 'bag' ? .42 : .75 + rand(0, .25), kind, spin: rand(-2.5, 2.5) };
    it.gone = false; it.eating = false; it.pull = 0; it.agit = 0; it.x = fx0; it.y = fy0;
    it.scale = kind === 'bag' ? .4 : .2;
    if (kind !== 'bag') { const l = it.label; l.on = true; l.gone = false; l.eating = false; l.pull = 0; l.lost = 0; }
  }
  function flight(it, dt) {
    const f = it.fly;
    if (f.delay > 0) { f.delay -= dt; return; }
    f.t = Math.min(1, f.t + dt / f.dur);
    const k = f.t, e = f.kind === 'bag' ? k * k : 1 - Math.pow(1 - k, 3);
    const dx = f.tx - f.fx, dy = f.ty - f.fy, l = len(dx, dy) || 1;
    const bow = f.kind === 'bag' ? 0 : Math.sin(k * Math.PI) * Math.min(l * .12, 60) * (it.i % 2 ? 1 : -1);
    it.x = f.fx + dx * e - dy / l * bow; it.y = f.fy + dy * e + dx / l * bow;
    if (f.kind === 'bag') {
      it.scale = .4 * (1 - k * .65); it.a += f.spin * 3 * dt;
      if (k >= 1) { it.fly = null; it.inBag = true; it.inBin = false; bagFill = Math.min(1, bagFill + 1 / items.length); emptied++; }
    } else {
      it.scale = .2 + .8 * smooth(clamp(k / .8, 0, 1)); it.a = f.spin * (1 - e);
      if (k >= 1) {
        it.fly = null; it.x = f.tx; it.y = f.ty; it.a = 0; it.vx = it.vy = it.av = 0; it.scale = 1; it.inBag = false; it.inBin = false; it.gone = false;
      }
    }
  }

  function tidyColumns() {
    const order = ['folder', 'shot', 'photo', 'video', 'doc', 'zip', 'audio'];
    const sorted = [...items].sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind));
    const rows = Math.max(1, Math.floor((H - 100) / 84));
    const cols = Math.ceil(sorted.length / rows);
    const pitch = Math.min(100, (dock.x - R * 2 - 70) / Math.max(cols - 1, 1));
    sorted.forEach((it, i) => {
      const col = Math.floor(i / rows), row = i % rows;
      launch(it, bag().x, bag().y, 60 + col * pitch, 44 + row * 84, i * .09, 'home');
    });
  }

  function putBack() {
    showActions([]);
    setPhase('putback');
    items.forEach((it, i) => launch(it, it.inBag || it.inBin ? bag().x : it.x, it.inBag || it.inBin ? bag().y : it.y, it.homeX, it.homeY, i * .07, 'home'));
    bagFill = 0;
  }
  function choose(kind) { showActions([]); drainTo = kind; setPhase('drain'); }
  let drainTo = 'trash';

  function step(dt) {
    t += dt; phaseT += dt;
    heavy *= Math.exp(-dt * 3); robot.bump *= Math.exp(-dt * 7); robot.shake *= Math.exp(-dt * 8); flash = Math.max(0, flash - dt);
    robot.lift += ((robot.picked ? 1 : 0) - robot.lift) * Math.min(1, dt * 11);
    const sucking = ['clean', 'hunt'].includes(phase) && !robot.picked;
    robot.brushV += ((sucking ? 26 : 0) * (1 - heavy * .7) - robot.brushV) * Math.min(1, dt * 3);
    robot.brush += robot.brushV * dt;

    switch (phase) {
      case 'ready': setStatus('Waiting on the dock'); break;
      case 'drop':
        robot.drop = Math.min(1, phaseT / .42);
        setStatus('Setting down');
        if (phaseT >= .42 && phaseT - dt < .42) {
          robot.shake = 1;
          for (const it of items) {
            const dx = it.x - dock.x, dy = it.y - (dock.y + R * .5), l = len(dx, dy) || 1;
            if (l < R * 3.6) { const k = 1 - l / (R * 3.6); it.vx += dx / l * 380 * k * k / it.mass; it.vy += dy / l * 380 * k * k / it.mass; it.agit = Math.max(it.agit, k); }
          }
        }
        if (phaseT > 1.1) setPhase('undock');
        break;
      case 'undock':
        setStatus('Leaving the dock');
        drive(170, 0, dt);
        if (len(robot.x - dock.x, robot.y - dock.y) > R * 1.9) { sweep = 0; setPhase(emptied ? 'clean' : 'scan'); if (emptied) planLanes(); }
        break;
      case 'scan': {
        setStatus('Mapping your desktop');
        drive(0, 3.1, dt);
        const prev = sweep; sweep += robot.w * dt;
        for (const it of items) {
          let a = Math.atan2(it.y - robot.y, it.x - robot.x) + Math.PI / 2;
          while (a < 0) a += 2 * Math.PI;
          if (a <= sweep && a > prev) it.ping = 1;
        }
        if (sweep > 2 * Math.PI) { planLanes(); setPhase('clean'); }
        break;
      }
      case 'clean':
        if (robot.picked) { setStatus('Put me down!', 'red'); break; }
        setStatus(flash > 0 ? 'Oof. Excuse me.' : heavy > .35 ? 'Big file. Straining…' : 'Cleaning');
        follow(dt);
        if (pathI >= path.length) { if (!remaining()) goDock(); else { huntTarget = null; setPhase('hunt'); } }
        break;
      case 'hunt':
        if (robot.picked) { setStatus('Put me down!', 'red'); break; }
        setStatus(flash > 0 ? 'Oof. Excuse me.' : 'Picking up stragglers');
        if (!huntTarget || huntTarget.gone || huntTarget.eating || !onFloor(huntTarget)) {
          let best = null, bd = 1e9;
          for (const it of items) if (onFloor(it) && !it.eating && !it.grabbed) { const d = len(it.x - robot.x, it.y - robot.y); if (d < bd) { bd = d; best = it; } }
          huntTarget = best; huntT = 0;
          if (!best) { if (!items.some(it => it.eating || it.grabbed)) goDock(); break; }
        }
        huntT += dt;
        path = [walkClamp(huntTarget.x, huntTarget.y)]; pathI = 0;
        if (huntT > 6) startEat(huntTarget, huntTarget);
        follow(dt);
        break;
      case 'return':
        if (robot.picked) { setStatus('Put me down!', 'red'); break; }
        setStatus('Heading home', 'amber');
        follow(dt);
        if (pathI >= path.length) { dockAligned = false; setPhase('dock'); }
        break;
      case 'dock': {
        setStatus('Reversing onto the dock', 'amber');
        const out = -Math.PI / 2, along = dock.y - robot.y;
        const want = along > R * .7 ? Math.atan2(robot.y - dock.y, robot.x - dock.x) : out;
        const err = wrap(want - robot.a);
        if (!dockAligned) { drive(0, clamp(err * 3, -2.2, 2.2), dt); if (Math.abs(err) < .06) dockAligned = true; }
        else {
          drive(-clamp(along * 2 + 40, 40, 170), clamp(err * 2.6, -.9, .9), dt);
          if (along < R * .5) robot.x += (dock.x - robot.x) * Math.min(1, dt * 5);
          if (along <= .5) { robot.x = dock.x; robot.y = dock.y; robot.a = out; robot.v = robot.w = 0; robot.shake = .35; emptyQueue = items.filter(it => it.inBin); emptyAcc = 0; setPhase('empty'); }
        }
        break;
      }
      case 'empty':
        setStatus('Self-emptying', 'green');
        robot.shake = Math.max(robot.shake, .08);
        if (phaseT > .5) {
          emptyAcc += dt * Math.max(emptyQueue.length, 6) / 2;
          while (emptyAcc >= 1 && emptyQueue.length) { emptyAcc -= 1; const it = emptyQueue.pop(); launch(it, robot.x + rand(-12, 12), robot.y + rand(-12, 12), bag().x + rand(-R * .5, R * .5), bag().y + rand(-R * .15, R * .15), 0, 'bag'); it.inBin = true; }
        }
        if (!emptyQueue.length && !items.some(it => it.fly)) afterEmpty();
        break;
      case 'ask': setStatus(mode === 'delete' ? `Permanently delete ${items.length} items?` : `Move ${items.length} items to the Trash?`, mode === 'delete' ? 'red' : 'green'); break;
      case 'drain':
        setStatus(drainTo === 'delete' ? 'Deleting…' : 'Moving to the Trash…', drainTo === 'delete' ? 'red' : 'green');
        bagFill = Math.max(0, bagFill - dt / 1.2); robot.shake = Math.max(robot.shake, .06);
        if (bagFill <= 0) {
          setPhase('done');
          showActions([button('Make a mess again', 'primary', restart)]);
        }
        break;
      case 'tidying':
        setStatus('Sorting into columns', 'green');
        if (!items.some(it => it.fly)) { setPhase('done'); showActions([button('Make a mess again', 'primary', putBack)]); }
        break;
      case 'done':
        setStatus(mode === 'tidy' ? 'Neat. Only the icons moved.' : drainTo === 'delete' ? 'Gone. Well, it’s a website. But you get the idea.' : 'All in the Trash. You can still get them back.', 'green');
        break;
      case 'putback':
        setStatus('Putting everything back', 'green');
        if (!items.some(it => it.fly)) { setPhase('settled'); showActions([button('Clean it again', 'primary', restart)]); }
        break;
      case 'settled': setStatus('Everything’s back'); break;
    }

    if (!robot.picked) {
      robot.a = wrap(robot.a + robot.w * dt);
      robot.x += fx() * robot.v * dt; robot.y += fy() * robot.v * dt;
      if (['clean', 'hunt', 'return'].includes(phase)) {
        const [cx, cy] = walkClamp(robot.x, robot.y);
        if (len(cx - robot.x, cy - robot.y) > .3) { if (t - lastBump > .9 && Math.abs(robot.v) > 70) { lastBump = t; robot.bump = .8; robot.v *= .4; } robot.x = cx; robot.y = cy; }
        if (keepOut(robot.x, robot.y)) {
          const u = R * 2 - (dock.y - robot.y), sv = R * 2.3 - Math.abs(robot.x - dock.x);
          if (u < sv) robot.y -= u; else robot.x += robot.x < dock.x ? -sv : sv;
        }
      }
    } else { robot.v = robot.w = 0; }

    updateItems(dt);
    updateParts(dt, sucking);
    stampClean(sucking);
  }
  let emptyQueue = [], emptyAcc = 0;

  function afterEmpty() {
    if (mode === 'tidy') { items.forEach(it => { it.inBag = false; }); tidyColumns(); bagFill = 0; setPhase('tidying'); return; }
    if (skipAsk()) { choose(mode); return; }
    setPhase('ask');
    showActions([
      mode === 'delete'
        ? button('Delete permanently', 'danger', () => choose('delete'))
        : button('Move to Trash', 'primary', () => choose('trash')),
      button('Put everything back', '', putBack),
    ]);
  }
  const skipAsk = () => false;

  function updateParts(dt, sucking) {
    if (sucking && Math.random() < dt * 34) {
      const a = robot.a + rand(-1.25, 1.25), d = R * rand(1.1, 1.95);
      parts.push({ x: robot.x + Math.cos(a) * d, y: robot.y + Math.sin(a) * d, vx: -Math.cos(a) * rand(40, 100), vy: -Math.sin(a) * rand(40, 100), life: rand(.25, .5), max: .5, size: rand(.6, 1.3), color: 'rgba(255,255,255,.75)', a: 0, air: true });
    }
    const p = intake();
    for (let i = parts.length - 1; i >= 0; i--) {
      const q = parts[i];
      q.life -= dt;
      if (q.life <= 0) { parts.splice(i, 1); continue; }
      if (sucking) { const dx = p.x - q.x, dy = p.y - q.y, l = len(dx, dy) || 1; if (l < R * 3) { const f = 1800 * (1 - l / (R * 3)); q.vx += dx / l * f * dt; q.vy += dy / l * f * dt; } }
      const k = Math.exp(-dt * 2.4); q.vx *= k; q.vy *= k; q.x += q.vx * dt; q.y += q.vy * dt; q.a += dt * 9;
    }
  }

  // The robot erases the dust and leaves a soft vacuumed nap behind it.
  let lastStamp = null;
  function stampClean(sucking) {
    if (!sucking || Math.abs(robot.v) < 6) { lastStamp = [robot.x, robot.y]; return; }
    const g = dustLayer.getContext('2d');
    const from = lastStamp || [robot.x, robot.y];
    g.save(); g.globalCompositeOperation = 'destination-out'; g.lineCap = 'round'; g.lineWidth = R * 1.7; g.strokeStyle = '#000';
    g.beginPath(); g.moveTo(from[0], from[1]); g.lineTo(robot.x, robot.y); g.stroke(); g.restore();
    // Replaces what's under the stroke rather than stacking on it, so turns stay clean.
    const l = laneLayer.getContext('2d');
    const seg = () => { l.beginPath(); l.moveTo(from[0], from[1]); l.lineTo(robot.x, robot.y); l.stroke(); };
    l.save(); l.lineCap = 'round'; l.lineWidth = R * 1.7; l.strokeStyle = '#000';
    l.globalCompositeOperation = 'destination-out'; seg();
    l.globalCompositeOperation = 'source-over'; l.lineWidth = R * 1.7 - .5;
    l.strokeStyle = Math.cos(robot.a) > 0 ? 'rgba(255,248,232,.15)' : 'rgba(255,248,232,.07)'; seg();
    l.restore();
    lastStamp = [robot.x, robot.y];
  }

  // ---------- drawing ----------
  function drawSprite(sprite, b, w, h, pull, ip) {
    // Up close it funnels in. From far away it just zips over, or it would smear across the floor.
    if (pull > 0 && len(ip.x - b.x, ip.y - b.y) < 120) { drawWarp(sprite, b, w, h, pull, ip); return; }
    if (pull > 0) b = { ...b, agit: 0, scale: (b.scale || 1) * (1 - pull * .55) };
    ctx.save();
    const jx = Math.sin(t * 33 + b.seed) * b.agit * b.agit * 1.4, jy = Math.cos(t * 29 + b.seed) * b.agit * b.agit * 1.4;
    ctx.translate(b.x + jx, b.y + jy);
    if (b.agit > .02) {
      // Leaning towards the intake: stretch along that direction.
      const ax = Math.atan2(ip.y - b.y, ip.x - b.x), d = len(ip.x - b.x, ip.y - b.y);
      const reach = clamp(1 - d / 190, 0, 1), st = 1 + b.agit * reach * reach * .32;
      ctx.rotate(ax); ctx.scale(st, 1 / Math.sqrt(st)); ctx.rotate(-ax);
    }
    ctx.rotate(b.a + (b.agit * .13 * Math.sin(t * (17 + (b.seed % 7)) + b.seed)));
    const sc = (b.scale || 1) * (1 + b.agit * .05);
    ctx.scale(sc, sc);
    ctx.drawImage(sprite, -w / 2, -h / 2, w, h);
    ctx.restore();
  }

  // The funnel: slices nearest the intake go first and every slice pinches as it travels.
  const warpTmp = document.createElement('canvas');
  function drawWarp(sprite, b, w, h, pull, ip) {
    const size = Math.ceil(Math.hypot(w, h));
    const px = Math.ceil(size * dpr);
    if (warpTmp.width !== px) { warpTmp.width = px; warpTmp.height = px; }
    const g = warpTmp.getContext('2d');
    g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, px, px);
    const axis = Math.atan2(ip.y - b.y, ip.x - b.x), d = Math.max(len(ip.x - b.x, ip.y - b.y), 1);
    g.setTransform(dpr, 0, 0, dpr, px / 2, px / 2);
    g.rotate(b.a - axis);
    g.drawImage(sprite, -w / 2, -h / 2, w, h);
    ctx.save(); ctx.translate(b.x, b.y); ctx.rotate(axis);
    const N = 16;
    for (let i = 0; i < N; i++) {
      const u0 = -size / 2 + size * i / N, u1 = u0 + size / N;
      const pos = u => {
        const rel = u / (size / 2), tv = clamp(pull * 1.75 - .75 * (.5 - .5 * rel), 0, 1), e = smooth(tv);
        return [u + (d - u) * e, Math.pow(1 - e, 2.2)];
      };
      const [x0, k0] = pos(u0), [x1] = pos(u1);
      const hh = size * k0;
      if (hh < .15) continue;
      ctx.drawImage(warpTmp, px * i / N, 0, Math.ceil(px / N), px, x0, -hh / 2, Math.max(x1 - x0, .4) + .4, hh);
    }
    ctx.restore();
  }

  function drawRobot() {
    const img = images.robot;
    const bounce = 1 - Math.pow(1 - robot.drop, 3);
    const s = (1 + (1 - bounce) * .55) * (1 + robot.lift * .13);
    const r = R * s, alpha = clamp(robot.drop / .35, 0, 1);
    const height = (1 - bounce) + robot.lift * .9;
    const sx = Math.sin(t * 83) * robot.shake * 2, sy = Math.cos(t * 71) * robot.shake * 2;
    ctx.save(); ctx.globalAlpha = alpha;
    // Shadow stays with the floor, and drifts away when lifted.
    const sh = ctx.createRadialGradient(0, 0, r * .72, 0, 0, r * 1.2 + height * 24);
    sh.addColorStop(0, `rgba(30,18,5,${.5 - height * .22})`); sh.addColorStop(1, 'rgba(30,18,5,0)');
    ctx.save(); ctx.translate(robot.x + 3 + height * 22, robot.y + 7 + height * 36);
    ctx.fillStyle = sh; ctx.beginPath(); ctx.arc(0, 0, r * 1.2 + height * 24, 0, 7); ctx.fill(); ctx.restore();

    // Side brushes.
    const blur = clamp(robot.brushV / 26, 0, 1);
    for (const [cx0, cy0, sign] of brushes()) {
      const cx = robot.x + (cx0 - robot.x) * s, cy = robot.y + (cy0 - robot.y) * s, br = r * .56;
      ctx.save(); ctx.translate(cx + sx, cy + sy);
      if (blur > .1) { ctx.fillStyle = `rgba(60,60,62,${.12 * blur})`; ctx.beginPath(); ctx.arc(0, 0, br * .95, 0, 7); ctx.fill(); }
      ctx.rotate(robot.brush * sign);
      ctx.lineCap = 'round'; ctx.lineWidth = .9;
      for (let a = 0; a < 3; a++) {
        ctx.save(); ctx.rotate(a * 2.094);
        for (let b = -2; b <= 2; b++) {
          ctx.strokeStyle = `rgba(55,55,58,${.75 - blur * .35})`;
          ctx.beginPath(); ctx.moveTo(0, 0); ctx.quadraticCurveTo(br * .5, sign * br * .1, br, sign * (br * .26) + b * 2.2); ctx.stroke();
        }
        ctx.restore();
      }
      ctx.restore();
    }

    // Body: the frame for this heading, so the light stays still as it turns.
    ctx.save(); ctx.translate(robot.x + sx, robot.y + sy);
    if (img.complete && img.naturalWidth) {
      const frames = 64, cols = 8, cell = 300;
      let f = Math.round(((robot.a % (2 * Math.PI)) + 2 * Math.PI) % (2 * Math.PI) / (2 * Math.PI) * frames) % frames;
      ctx.beginPath(); ctx.arc(0, 0, r - .4, 0, 7); ctx.clip();
      ctx.drawImage(img, (f % cols) * cell, Math.floor(f / cols) * cell, cell, cell, -r, -r, r * 2, r * 2);
    } else {
      ctx.fillStyle = '#ddd'; ctx.beginPath(); ctx.arc(0, 0, r, 0, 7); ctx.fill();
    }
    ctx.restore(); ctx.restore();
  }

  function drawDock() {
    const bounce = 1 - Math.pow(1 - robot.drop, 3);
    const s = (1 + (1 - bounce) * .55) * (R / 92);
    const alpha = clamp(robot.drop / .35, 0, 1);
    ctx.save(); ctx.globalAlpha = alpha; ctx.translate(dock.x, dock.y); ctx.scale(s, s);
    const draw = img => { if (img.complete && img.naturalWidth) ctx.drawImage(img, -165, -242.64, 330, 480); };
    draw(images.dockEmpty);
    if (bagFill > 0) { ctx.globalAlpha = alpha * Math.min(1, bagFill * 1.15); draw(images.dockFull); }
    ctx.restore();
  }

  function render() {
    if (!floorLayer) return;
    ctx.setTransform(dpr * scale, 0, 0, dpr * scale, 0, 0);
    ctx.drawImage(floorLayer, 0, 0, W, H);
    ctx.drawImage(laneLayer, 0, 0, W, H);
    ctx.drawImage(dustLayer, 0, 0, W, H);
    const ip = intake();

    if (phase === 'scan') {
      const g = ctx.createConicGradient(sweep - Math.PI / 2 - 1.1, robot.x, robot.y);
      g.addColorStop(0, 'rgba(8,120,179,0)'); g.addColorStop(.17, 'rgba(8,120,179,.26)'); g.addColorStop(.1752, 'rgba(8,120,179,0)'); g.addColorStop(1, 'rgba(8,120,179,0)');
      ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    }

    const flat = [], top = [], flying = [];
    for (const it of items) {
      if (it.inBag && !it.fly) continue;
      if (it.inBin && !it.fly) continue;
      if (it.fly && it.fly.delay > 0 && it.inBag) continue;
      if (it.fly && it.fly.kind === 'bag') flying.push(it);
      else if (it.eating || it.fly || it.agit > .02) top.push(it);
      else flat.push(it);
    }
    const drawLabel = it => {
      const l = it.label;
      if (l.gone && !it.fly) return;
      if (l.on) {
        const sc = it.scale || 1;
        drawSprite(it.lab, { x: it.x - Math.sin(it.a) * 37 * sc, y: it.y + Math.cos(it.a) * 37 * sc, a: it.a, agit: it.agit * .6, seed: l.seed, scale: sc }, LABEL_W, LABEL_H, 0, ip);
      } else drawSprite(it.lab, l, LABEL_W, LABEL_H, l.eating ? l.pull : 0, ip);
    };
    for (const it of flat) { drawLabel(it); }
    for (const it of flat) { drawSprite(it.icon, it, ICON, ICON, 0, ip); ping(it); }
    for (const it of top) drawLabel(it);
    for (const it of top) if (!it.gone || it.fly) {
      if (!it.eating && it.agit > .02) {
        ctx.save(); ctx.globalAlpha = .18 * it.agit; ctx.filter = 'blur(3px)';
        drawSprite(it.icon, { ...it, x: it.x + 3, y: it.y + 6, agit: 0 }, ICON, ICON, 0, ip);
        ctx.restore();
      }
      drawSprite(it.icon, it, ICON, ICON, it.eating ? it.pull : 0, ip);
      ping(it);
    }
    for (const it of items) if (it.gone && !it.label.gone && !it.label.on) drawLabel(it);

    drawDock();

    for (const q of parts) {
      ctx.save(); ctx.globalAlpha = clamp(q.life / q.max * 2, 0, 1) * (q.air ? .6 : 1); ctx.fillStyle = q.color;
      ctx.translate(q.x, q.y); ctx.rotate(q.a);
      if (q.air) { ctx.beginPath(); ctx.arc(0, 0, q.size, 0, 7); ctx.fill(); }
      else ctx.fillRect(-q.size, -q.size * .55, q.size * 2, q.size * 1.1);
      ctx.restore();
    }
    drawRobot();
    for (const it of flying) if (it.fly.delay <= 0) drawSprite(it.icon, it, ICON, ICON, 0, ip);
  }
  function ping(it) {
    if (it.ping <= 0) return;
    ctx.save(); ctx.strokeStyle = `rgba(8,120,179,${it.ping * .9})`; ctx.lineWidth = 1.5;
    rr(ctx, it.x - ICON / 2 - 3, it.y - ICON / 2 - 3, ICON + 6, ICON + 6, 8); ctx.stroke(); ctx.restore();
  }

  // ---------- input ----------
  const toWorld = e => { const r = canvas.getBoundingClientRect(); return { x: (e.clientX - r.left) / scale, y: (e.clientY - r.top) / scale }; };
  const hitRobot = p => len(p.x - robot.x, p.y - robot.y) < R && ['clean', 'hunt', 'return', 'scan'].includes(phase);
  const hitItem = p => {
    let best = null, bd = 30;
    for (const it of items) if (onFloor(it) && !it.eating) { const d = len(it.x - p.x, it.y - p.y); if (d < bd) { bd = d; best = it; } }
    return best;
  };
  canvas.addEventListener('pointerdown', e => {
    const p = toWorld(e);
    if (hitRobot(p)) { robot.picked = true; canvas.setPointerCapture(e.pointerId); canvas.style.cursor = 'grabbing'; e.preventDefault(); return; }
    const it = hitItem(p);
    if (it) { grabbed = it; it.grabbed = true; lastDrag = [p.x, p.y]; dragV = [0, 0]; canvas.setPointerCapture(e.pointerId); canvas.style.cursor = 'grabbing'; e.preventDefault(); }
  });
  canvas.addEventListener('pointermove', e => {
    const p = toWorld(e);
    mouse = e.pointerType === 'mouse' ? p : null;
    if (robot.picked) { [robot.x, robot.y] = walkClamp(p.x, p.y); return; }
    if (grabbed) {
      grabbed.x = p.x; grabbed.y = p.y;
      dragV = [dragV[0] * .6 + (p.x - lastDrag[0]) * 60 * .4, dragV[1] * .6 + (p.y - lastDrag[1]) * 60 * .4];
      lastDrag = [p.x, p.y];
      return;
    }
    canvas.style.cursor = hitRobot(p) || hitItem(p) ? 'grab' : 'default';
  });
  const release = () => {
    if (robot.picked) {
      robot.picked = false; robot.shake = .6; lastStamp = null;
      if (phase === 'clean') planLanes();
      if (phase === 'return') goDock();
    }
    if (grabbed) { grabbed.grabbed = false; grabbed.vx = dragV[0]; grabbed.vy = dragV[1]; grabbed.av = dragV[0] * .01; grabbed = null; }
    canvas.style.cursor = 'default';
  };
  canvas.addEventListener('pointerup', release);
  canvas.addEventListener('pointercancel', release);
  canvas.addEventListener('pointerleave', () => { mouse = null; });

  document.getElementById('modes').addEventListener('click', e => {
    const b = e.target.closest('button'); if (!b) return;
    mode = b.dataset.mode;
    for (const x of e.currentTarget.children) x.setAttribute('aria-checked', x === b ? 'true' : 'false');
    if (phase === 'ask') afterEmpty();
    if (phase === 'done' || phase === 'settled') restart();
  });

  // ---------- run ----------
  let visible = false, last = 0, acc = 0;
  function frame(now) {
    requestAnimationFrame(frame);
    // Asked every frame: a one-off visibility signal can be missed after a reload.
    const box = stage.getBoundingClientRect();
    const shown = Math.min(box.bottom, innerHeight) - Math.max(box.top, 0);
    visible = shown > 0;
    if (!visible || !ready) { last = now; return; }
    if (!started && !reduceMotion && shown / box.height > .45) { started = true; restart(); }
    let dt = Math.min((now - last) / 1000, .05); last = now; acc += dt;
    const h = 1 / 120; let n = 0;
    while (acc >= h && n < 8) { step(h); acc -= h; n++; }
    if (n === 8) acc = 0;
    render();
  }

  // Waits for a real size, which a hidden tab or pane may not have yet.
  let ready = false, lastSize = 0;
  function settleAtDock() {
    makeItems();
    Object.assign(robot, { x: dock.x, y: dock.y, a: -Math.PI / 2, v: 0, w: 0, picked: false });
    bagFill = 0; collected = 0; emptied = 0; parts = []; lastStamp = null;
  }
  function measure() {
    const width = stage.getBoundingClientRect().width;
    if (width < 10 || Math.abs(width - lastSize) < 1) return;
    const first = !ready;
    if (!layout()) return;
    lastSize = width; ready = true;
    settleAtDock();
    if (first) {
      if (reduceMotion) { robot.drop = 1; showActions([button('Start cleaning', 'primary', () => { started = true; restart(); })]); }
    } else if (started) {
      // The floor changed shape mid-run, so everything goes back to the start of a fresh clean.
      robot.drop = 1; showActions([button('Clean it', 'primary', restart)]); setPhase('settled');
    }
  }
  let resizeTimer;
  new ResizeObserver(() => { clearTimeout(resizeTimer); resizeTimer = setTimeout(measure, ready ? 150 : 0); }).observe(stage);

  requestAnimationFrame(frame);
})();
