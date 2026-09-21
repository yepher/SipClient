import Foundation

// The HTML template, kept apart from the data marshalling in
// `CallChartHTMLExport` so neither file is unreadable.
//
// The page draws to canvases rather than emitting thousands of SVG
// elements: a few minutes of call is tens of thousands of points, which
// SVG handles badly in a browser. It has no dependencies of any kind.
extension CallChartHTMLExport {

    static func page(title: String,
                     meta: String,
                     nominal: String,
                     duration: String,
                     audioOffset: String,
                     ts: String,
                     ds: String,
                     js: String,
                     wave: String,
                     audioSrc: String,
                     omittedNote: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root {
          --bg: #1e1e1e; --panel: #262626; --fg: #ececec; --dim: #9a9a9a;
          --grid: #3a3a3a; --delta: #3b8eea; --jitter: #e8912d;
          --near: #35c759; --far: #bf5af2; --head: #ffffff;
        }
        @media (prefers-color-scheme: light) {
          :root {
            --bg: #ffffff; --panel: #f4f4f6; --fg: #1a1a1a; --dim: #666;
            --grid: #d8d8dc; --delta: #0a68c9; --jitter: #b4650c;
            --near: #1a8a3c; --far: #7d2fb8; --head: #111111;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 18px; background: var(--bg); color: var(--fg);
          font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI",
                system-ui, sans-serif;
        }
        h1 { font-size: 17px; margin: 0 0 2px; }
        .meta, .hint { color: var(--dim); font-size: 12px; }
        .bar {
          display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
          margin: 14px 0 6px; padding: 10px; border-radius: 8px;
          background: var(--panel);
        }
        audio { height: 32px; }
        button {
          font: inherit; padding: 4px 10px; border-radius: 6px;
          border: 1px solid var(--grid); background: transparent;
          color: var(--fg); cursor: pointer;
        }
        button:disabled { opacity: .45; cursor: default; }
        .readout { font-variant-numeric: tabular-nums; min-height: 18px;
                   margin: 6px 0; font-size: 12px; }
        .readout .d { color: var(--delta); }
        .readout .j { color: var(--jitter); }
        .lane { margin-bottom: 10px; }
        .label { font-size: 11px; margin-bottom: 2px; }
        .label.w { color: var(--dim); }
        .label.d { color: var(--delta); }
        .label.j { color: var(--jitter); }
        .swatch-near { color: var(--near); }
        .swatch-far { color: var(--far); }
        /* The CSS height must be explicit. The drawing code sets the
           height attribute (the backing store) to clientHeight x dpr; if
           layout height came from that attribute instead, each redraw
           would enlarge the element and the canvas would grow without
           bound. CSS height pins the layout size so the attribute only
           controls resolution. */
        canvas { width: 100%; display: block; cursor: crosshair; height: 200px; }
        canvas#wave { height: 120px; }
        .note { color: var(--jitter); font-size: 12px; margin: 6px 0; }
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        <div class="meta">\(meta)</div>
        \(omittedNote.isEmpty ? "" : "<div class=\"note\">" + omittedNote + "</div>")
        <div class="bar">
          <audio id="au" controls preload="metadata"></audio>
          <span class="hint">left = us &middot; right = peer &middot;
            click a chart to move the playhead &middot; drag to zoom</span>
          <span style="flex:1"></span>
          <button id="reset" disabled>Reset zoom</button>
        </div>
        <div class="readout" id="readout">&nbsp;</div>

        <div class="lane" id="lane-wave">
          <div class="label w">Audio &mdash;
            <span class="swatch-near">us</span> /
            <span class="swatch-far">peer</span></div>
          <canvas id="wave"></canvas>
        </div>
        <div class="lane">
          <div class="label d">&Delta; inter-arrival (ms) &mdash; ideal \(nominal) ms</div>
          <canvas id="delta"></canvas>
        </div>
        <div class="lane">
          <div class="label j">Jitter (ms) &mdash; ideal 0 ms</div>
          <canvas id="jitter"></canvas>
        </div>

        <script>
        const T = [\(ts)], D = [\(ds)], J = [\(js)];
        const WAVE = \(wave);
        const AUDIO_SRC = \(audioSrc);
        const NOMINAL = \(nominal), DURATION = \(duration);
        const AUDIO_OFFSET = \(audioOffset);

        const au = document.getElementById("au");
        if (AUDIO_SRC) { au.src = AUDIO_SRC; } else { au.style.display = "none"; }

        let lo = 0, hi = DURATION > 0 ? DURATION : 1;
        let hover = null, drag = null;

        function lerpX(t, w) { return (t - lo) / (hi - lo) * w; }
        function timeAt(x, w) { return lo + (x / w) * (hi - lo); }

        // First index with T[i] >= t.
        function lowerBound(t) {
          let a = 0, b = T.length;
          while (a < b) { const m = (a + b) >> 1; if (T[m] < t) a = m + 1; else b = m; }
          return a;
        }

        function prep(cv) {
          const dpr = window.devicePixelRatio || 1;
          const w = cv.clientWidth, h = cv.clientHeight;
          if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
            cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
          }
          const ctx = cv.getContext("2d");
          ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
          ctx.clearRect(0, 0, w, h);
          return { ctx, w, h };
        }

        function css(name) {
          return getComputedStyle(document.documentElement)
                 .getPropertyValue(name).trim();
        }

        function niceTicks(max, count) {
          if (max <= 0) return [0];
          const raw = max / count;
          const mag = Math.pow(10, Math.floor(Math.log10(raw)));
          const norm = raw / mag;
          const step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10) * mag;
          const out = [];
          for (let v = 0; v <= max + step / 2; v += step) out.push(v);
          return out;
        }

        function fmtClock(t) {
          const m = Math.floor(t / 60), s = t - m * 60;
          return m + ":" + (s < 10 ? "0" : "") + s.toFixed(2);
        }

        // Top padding keeps the highest y-axis label from being clipped
        // against the canvas edge.
        const PAD_L = 42, PAD_B = 18, PAD_T = 8;

        function drawAxes(ctx, w, h, yMax, ticks) {
          ctx.strokeStyle = css("--grid");
          ctx.fillStyle = css("--dim");
          ctx.lineWidth = 1;
          ctx.font = "10px system-ui, sans-serif";
          ctx.textAlign = "right"; ctx.textBaseline = "middle";
          const plotH = h - PAD_B - PAD_T;
          for (const v of ticks) {
            const y = PAD_T + plotH - (v / yMax) * plotH;
            ctx.beginPath();
            ctx.moveTo(PAD_L, Math.round(y) + 0.5);
            ctx.lineTo(w, Math.round(y) + 0.5);
            ctx.stroke();
            ctx.fillText(String(+v.toFixed(2)), PAD_L - 6, y);
          }
          // Time ticks along the bottom.
          ctx.textAlign = "center"; ctx.textBaseline = "top";
          const span = hi - lo;
          const tt = niceTicks(span, 6);
          let stepT = tt.length > 1 ? tt[1] - tt[0] : span;
          // A zero step would loop forever on a degenerate span.
          if (!(stepT > 0)) stepT = Math.max(span, 1e-6);
          for (let t = Math.ceil(lo / stepT) * stepT; t <= hi; t += stepT) {
            const x = PAD_L + lerpX(t, w - PAD_L);
            ctx.strokeStyle = css("--grid");
            ctx.beginPath();
            ctx.moveTo(Math.round(x) + 0.5, PAD_T);
            ctx.lineTo(Math.round(x) + 0.5, PAD_T + plotH);
            ctx.stroke();
            ctx.fillStyle = css("--dim");
            ctx.fillText(fmtClock(t), x, PAD_T + plotH + 3);
          }
        }

        function overlays(ctx, w, h) {
          const plotW = w - PAD_L, plotH = h - PAD_B - PAD_T;
          if (drag) {
            const a = PAD_L + lerpX(Math.min(drag.a, drag.b), plotW);
            const b = PAD_L + lerpX(Math.max(drag.a, drag.b), plotW);
            ctx.fillStyle = "rgba(59,142,234,0.18)";
            ctx.fillRect(a, PAD_T, b - a, plotH);
          }
          if (hover !== null && hover >= lo && hover <= hi) {
            const x = PAD_L + lerpX(hover, plotW);
            ctx.strokeStyle = css("--dim");
            ctx.beginPath();
            ctx.moveTo(Math.round(x) + 0.5, PAD_T);
            ctx.lineTo(Math.round(x) + 0.5, PAD_T + plotH);
            ctx.stroke();
          }
          if (AUDIO_SRC) {
            const p = AUDIO_OFFSET + au.currentTime;
            if (p >= lo && p <= hi) {
              const x = PAD_L + lerpX(p, plotW);
              ctx.strokeStyle = css("--head");
              ctx.lineWidth = 1.5;
              ctx.beginPath();
              ctx.moveTo(Math.round(x) + 0.5, PAD_T);
              ctx.lineTo(Math.round(x) + 0.5, PAD_T + plotH);
              ctx.stroke();
              ctx.lineWidth = 1;
            }
          }
        }

        function drawSeries(id, arr, colorVar, yFloor) {
          const cv = document.getElementById(id);
          const { ctx, w, h } = prep(cv);
          const plotW = w - PAD_L, plotH = h - PAD_B - PAD_T;
          let i0 = Math.max(0, lowerBound(lo) - 1);
          let i1 = Math.min(T.length, lowerBound(hi) + 1);
          let peak = 0;
          for (let i = i0; i < i1; i++) if (arr[i] > peak) peak = arr[i];
          const yMax = Math.max(yFloor, peak * 1.2) || 1;
          drawAxes(ctx, w, h, yMax, niceTicks(yMax, 4));

          // Reference line (ideal value).
          const refV = id === "delta" ? NOMINAL : 0;
          const refY = PAD_T + plotH - (refV / yMax) * plotH;
          ctx.save();
          ctx.strokeStyle = "rgba(60,190,110,0.75)";
          ctx.setLineDash([3, 3]);
          ctx.beginPath();
          ctx.moveTo(PAD_L, Math.round(refY) + 0.5);
          ctx.lineTo(w, Math.round(refY) + 0.5);
          ctx.stroke();
          ctx.restore();

          ctx.beginPath();
          let started = false;
          for (let i = i0; i < i1; i++) {
            const x = PAD_L + lerpX(T[i], plotW);
            const y = PAD_T + plotH - (arr[i] / yMax) * plotH;
            if (started) ctx.lineTo(x, y); else { ctx.moveTo(x, y); started = true; }
          }
          ctx.strokeStyle = css(colorVar);
          ctx.stroke();
          overlays(ctx, w, h);
        }

        function drawWave() {
          const cv = document.getElementById("wave");
          const { ctx, w, h } = prep(cv);
          const plotW = w - PAD_L, plotH = h - PAD_B - PAD_T;
          const nearMid = PAD_T + plotH * 0.25, farMid = PAD_T + plotH * 0.75;
          const half = plotH * 0.22;

          ctx.strokeStyle = css("--grid");
          ctx.beginPath();
          ctx.moveTo(PAD_L, nearMid); ctx.lineTo(w, nearMid);
          ctx.moveTo(PAD_L, farMid);  ctx.lineTo(w, farMid);
          ctx.stroke();

          if (WAVE) {
            const n = WAVE.nMin.length;
            const nearPath = new Path2D(), farPath = new Path2D();
            for (let px = 0; px < plotW; px++) {
              const t0 = timeAt(px, plotW) - AUDIO_OFFSET;
              const t1 = timeAt(px + 1, plotW) - AUDIO_OFFSET;
              let a = Math.max(0, Math.floor(t0 / WAVE.dt));
              let b = Math.min(n, Math.max(a + 1, Math.ceil(t1 / WAVE.dt)));
              if (a >= n || b <= 0) continue;
              const step = Math.max(1, Math.floor((b - a) / 48));
              let nmin = 0, nmax = 0, fmin = 0, fmax = 0;
              for (let i = a; i < b; i += step) {
                if (WAVE.nMin[i] < nmin) nmin = WAVE.nMin[i];
                if (WAVE.nMax[i] > nmax) nmax = WAVE.nMax[i];
                if (WAVE.fMin[i] < fmin) fmin = WAVE.fMin[i];
                if (WAVE.fMax[i] > fmax) fmax = WAVE.fMax[i];
              }
              const x = PAD_L + px + 0.5;
              nearPath.moveTo(x, nearMid - (nmax / 127) * half);
              nearPath.lineTo(x, nearMid - (nmin / 127) * half);
              if (!WAVE.mono) {
                farPath.moveTo(x, farMid - (fmax / 127) * half);
                farPath.lineTo(x, farMid - (fmin / 127) * half);
              }
            }
            ctx.strokeStyle = css("--near"); ctx.stroke(nearPath);
            ctx.strokeStyle = css("--far");  ctx.stroke(farPath);
          } else {
            ctx.fillStyle = css("--dim");
            ctx.font = "12px system-ui, sans-serif";
            ctx.textAlign = "center";
            ctx.fillText("No recording for this call",
                         PAD_L + plotW / 2, PAD_T + plotH / 2);
          }
          overlays(ctx, w, h);
        }

        function drawAll() {
          drawWave();
          drawSeries("delta", D, "--delta", NOMINAL * 2);
          drawSeries("jitter", J, "--jitter", 10);
          document.getElementById("reset").disabled =
            (lo === 0 && Math.abs(hi - (DURATION || 1)) < 1e-9);
        }

        function updateReadout() {
          const el = document.getElementById("readout");
          if (hover === null) {
            el.innerHTML = "&nbsp;";
            return;
          }
          let i = lowerBound(hover);
          if (i >= T.length) i = T.length - 1;
          if (i > 0 && Math.abs(T[i - 1] - hover) < Math.abs(T[i] - hover)) i--;
          if (i < 0) { el.innerHTML = "&nbsp;"; return; }
          el.innerHTML = "t +" + T[i].toFixed(3) + " s &nbsp; "
            + "<span class='d'>&Delta; " + D[i].toFixed(2) + " ms</span> &nbsp; "
            + "<span class='j'>jit " + J[i].toFixed(2) + " ms</span>";
        }

        // --- interaction, shared by every lane -------------------------
        function bind(cv) {
          cv.addEventListener("mousemove", e => {
            const r = cv.getBoundingClientRect();
            const x = e.clientX - r.left - PAD_L;
            const plotW = r.width - PAD_L;
            if (x < 0 || x > plotW) { hover = null; }
            else {
              hover = timeAt(x, plotW);
              if (drag) drag.b = hover;
            }
            updateReadout(); drawAll();
          });
          cv.addEventListener("mouseleave", () => {
            hover = null; updateReadout(); drawAll();
          });
          cv.addEventListener("mousedown", e => {
            const r = cv.getBoundingClientRect();
            const x = e.clientX - r.left - PAD_L;
            const plotW = r.width - PAD_L;
            if (x < 0 || x > plotW) return;
            const t = timeAt(x, plotW);
            drag = { a: t, b: t, moved: false };
          });
          window.addEventListener("mouseup", () => {
            if (!drag) return;
            const a = Math.min(drag.a, drag.b), b = Math.max(drag.a, drag.b);
            const wasDrag = (b - a) > (hi - lo) * 0.005;
            if (wasDrag) { lo = a; hi = b; }
            else if (AUDIO_SRC) {
              // A click, not a drag: move the playhead there.
              const t = drag.a - AUDIO_OFFSET;
              au.currentTime = Math.max(0, Math.min(au.duration || 0, t));
            }
            drag = null;
            drawAll();
          });
        }
        ["wave", "delta", "jitter"].forEach(id => bind(document.getElementById(id)));

        document.getElementById("reset").addEventListener("click", () => {
          lo = 0; hi = DURATION > 0 ? DURATION : 1; drawAll();
        });

        // Keep the playhead moving without redrawing when nothing is happening.
        let raf = null;
        function tick() { drawAll(); raf = requestAnimationFrame(tick); }
        au.addEventListener("play", () => { if (!raf) tick(); });
        function stopTick() {
          if (raf) { cancelAnimationFrame(raf); raf = null; }
          drawAll();
        }
        au.addEventListener("pause", stopTick);
        au.addEventListener("ended", stopTick);
        au.addEventListener("seeked", drawAll);

        window.addEventListener("resize", drawAll);
        matchMedia("(prefers-color-scheme: dark)").addEventListener("change", drawAll);
        drawAll();
        </script>
        </body>
        </html>
        """
    }
}
