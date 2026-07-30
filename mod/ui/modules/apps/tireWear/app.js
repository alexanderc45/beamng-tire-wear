// Realistic Tire Wear -- UI app.
// AngularJS 1.5.8 directive (the only mod-accessible UI framework in 0.38).
// Data arrives on the "alexTireWear" stream pushed by the vehicle extension. The
// primary per-tire number is remaining tread depth in mm; the fill bar is wear %.
angular.module("beamng.apps").directive("alexTireWear", ["$timeout", function ($timeout) {
  "use strict";

  var STREAM = "alexTireWear";
  var WAIT_MS = 3000;   // how long "waiting for tire data" stays before we call it dead

  // Markup + styles live here: BeamNG's app loader only reads app.json / app.js,
  // there is no app.html, so the template is a string.
  var STYLE = [
    ".atw{position:relative;width:100%;height:100%;box-sizing:border-box;overflow:hidden;",
    "font-family:'Roboto','Segoe UI',Arial,sans-serif;color:#fff;",
    "background:rgba(18,18,20,0.55);border-radius:6px}",
    ".atw-grid{display:flex;flex-wrap:wrap;width:100%;height:100%}",
    ".atw-tile{position:relative;box-sizing:border-box;width:50%}",
    ".atw-inner{position:absolute;top:2px;left:2px;right:2px;bottom:2px;overflow:hidden;",
    "border-radius:4px;background:rgba(255,255,255,0.07);border:1px solid rgba(255,255,255,0.13)}",
    ".atw-fill{position:absolute;left:0;right:0;bottom:0;height:0;opacity:0.5}",
    ".atw-body{position:absolute;top:0;left:0;right:0;bottom:0;padding:2px 4px;box-sizing:border-box}",
    ".atw-row{display:flex;justify-content:space-between;align-items:baseline}",
    ".atw-name{font-size:10px;letter-spacing:0.5px;opacity:0.8}",
    ".atw-temp{font-size:11px;font-weight:600}",
    ".atw-depth{position:absolute;left:4px;bottom:1px;font-size:17px;font-weight:600;line-height:1}",
    ".atw-unit{font-size:9px;font-weight:400;opacity:0.7;margin-left:1px}",
    ".atw-blown .atw-inner{border-color:rgba(255,90,90,0.8)}",
    ".atw-blown .atw-depth{color:#ff5a5a;font-size:13px}",
    ".atw-msg{position:absolute;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;",
    "justify-content:center;text-align:center;padding:0 6px;font-size:11px;opacity:0.55}",
    // gear toggle + tuning panel
    ".atw-gear{position:absolute;top:1px;right:2px;width:15px;height:15px;z-index:3;",
    "cursor:pointer;border:0;padding:0;background:transparent;color:#fff;opacity:0.35;",
    "font-size:12px;line-height:15px;text-align:center;border-radius:3px}",
    ".atw-gear:hover{opacity:0.9;background:rgba(255,255,255,0.12)}",
    ".atw-gear.on{opacity:0.95;background:rgba(255,255,255,0.18)}",
    ".atw-tune{position:absolute;top:0;left:0;right:0;bottom:0;z-index:2;display:none;",
    "overflow-y:auto;overflow-x:hidden;padding:16px 5px 5px 5px;box-sizing:border-box;",
    "background:rgba(12,12,14,0.94)}",
    ".atw-tune.open{display:block}",
    ".atw-tr{margin-bottom:5px}",
    ".atw-tl{display:flex;justify-content:space-between;align-items:baseline;",
    "font-size:9px;letter-spacing:0.3px;opacity:0.75;margin-bottom:1px}",
    ".atw-tv{font-weight:600;opacity:1;font-variant-numeric:tabular-nums}",
    ".atw-tune input[type=range]{width:100%;height:11px;margin:0;padding:0;",
    "-webkit-appearance:none;background:transparent;display:block}",
    ".atw-tune input[type=range]::-webkit-slider-runnable-track{height:3px;border-radius:2px;",
    "background:rgba(255,255,255,0.22)}",
    ".atw-tune input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:11px;",
    "height:11px;margin-top:-4px;border-radius:50%;background:#51c06a;border:0}",
    ".atw-btn{display:block;width:100%;box-sizing:border-box;margin:0;padding:3px 4px;",
    "font-family:inherit;font-size:9px;letter-spacing:0.3px;color:#fff;cursor:pointer;",
    "border:1px solid rgba(255,255,255,0.22);border-radius:3px;",
    "background:rgba(255,255,255,0.09)}",
    ".atw-btn:hover{background:rgba(255,255,255,0.18)}",
    ".atw-btn.on{background:rgba(81,192,106,0.30);border-color:rgba(81,192,106,0.65)}",
    ".atw-btn.off{background:rgba(255,255,255,0.05);opacity:0.6}",
    ".atw-btn.wide{margin-top:2px}",
    ".atw-sep{height:1px;background:rgba(255,255,255,0.13);margin:6px 0 5px 0}"
  ].join("");

  // Only sliders and buttons: BeamNG auto-binds setCEFTyping(true/false) to focus/blur
  // of Angular-compiled <input type=text|number|password|search> and <textarea>
  // (lib/int/beamng-core.js bngLinkInput, registered as element directives on "input"
  // and "textarea"). This panel is built with plain DOM and never $compile'd, so it
  // would NOT get that binding -- a number field here would send keystrokes to the car.
  // input[type=range] is explicitly not a text input by that helper's own test, so
  // sliders are safe without any of it.
  function row(label, id, minV, maxV, step) {
    return '<div class="atw-tr"><div class="atw-tl"><span>' + label +
      '</span><span class="atw-tv" data-v="' + id + '"></span></div>' +
      '<input type="range" data-s="' + id + '" min="' + minV + '" max="' + maxV +
      '" step="' + step + '"></div>';
  }

  var TEMPLATE = [
    '<div class="atw">',
    "<style>", STYLE, "</style>",
    '<div class="atw-grid"></div>',
    '<div class="atw-msg">waiting for tire data</div>',
    '<div class="atw-tune">',
      row("TREAD NOW", "tread", 0, 100, 1),
      '<button class="atw-btn" data-a="applyTread">APPLY TREAD</button>',
      '<div class="atw-sep"></div>',
      row("NEW TREAD DEPTH", "treadDepthNew", 4, 14, 0.5),
      row("WEAR SPEED", "wearSpeed", 0.25, 5, 0.25),
      row("TIRE HEATING", "heatSpeed", 0.25, 4, 0.25),
      '<div class="atw-tr"><button class="atw-btn" data-a="tempAffectsGrip"></button></div>',
      '<div class="atw-tr"><button class="atw-btn" data-a="sparksEnabled"></button></div>',
      row("SPARK WINDOW", "sparkTreadWindow", 0.1, 1, 0.05),
      row("SPARK AMOUNT", "sparkAmount", 0.25, 3, 0.25),
      row("SPARK WIDTH", "sparkThickness", 0.01, 0.3, 0.01),
      '<div class="atw-sep"></div>',
      '<button class="atw-btn wide" data-a="reset">RESET TO DEFAULTS</button>',
    "</div>",
    '<button class="atw-gear" title="Tuning">&#9881;</button>',
    "</div>"
  ].join("");

  // Must match the extension's `baseline` / `limits` tables.
  var DEFAULTS = {
    treadDepthNew: 8.0,
    wearSpeed: 1.0,
    heatSpeed: 1.0,
    tempAffectsGrip: true,
    sparksEnabled: true,
    sparkTreadWindow: 0.2,
    sparkAmount: 1.0,
    sparkThickness: 0.05
  };
  var TUNING_KEYS = ["treadDepthNew", "wearSpeed", "heatSpeed", "sparkTreadWindow",
                     "sparkAmount", "sparkThickness"];
  var TOGGLE_KEYS = ["tempAffectsGrip", "sparksEnabled"];
  // Vanilla apps persist app-local state in localStorage under this exact naming
  // convention -- e.g. 'apps:indicatedAirspeed.unit' in the shipped IndicatedAirspeed
  // app, 'apps:simpleTrip.mode' in SimpleTrip.
  var LS_KEY = "apps:alexTireWear.tuning";

  function clampNum(v, lo, hi, fallback) {
    v = parseFloat(v);
    if (!isFinite(v)) { return fallback; }
    return v < lo ? lo : (v > hi ? hi : v);
  }

  var LIMITS = {
    treadDepthNew: [1, 30],
    wearSpeed: [0.25, 5],
    heatSpeed: [0.25, 4],
    sparkTreadWindow: [0.1, 1],
    sparkAmount: [0.25, 3],
    sparkThickness: [0.01, 0.30]
  };

  function sanitize(raw) {
    var out = {}, i, k;
    for (i = 0; i < TUNING_KEYS.length; i++) {
      k = TUNING_KEYS[i];
      out[k] = clampNum(raw && raw[k], LIMITS[k][0], LIMITS[k][1], DEFAULTS[k]);
    }
    for (i = 0; i < TOGGLE_KEYS.length; i++) {
      k = TOGGLE_KEYS[i];
      out[k] = typeof (raw && raw[k]) === "boolean" ? raw[k] : DEFAULTS[k];
    }
    return out;
  }

  function loadTuning() {
    var raw = null;
    try { raw = JSON.parse(localStorage.getItem(LS_KEY)); } catch (e) { raw = null; }
    var t = sanitize(raw && raw.tuning);
    var tok = raw && typeof raw.token === "number" && isFinite(raw.token) ? raw.token : 0;
    return { tuning: t, token: tok || Date.now() };
  }

  function saveTuning(t, token) {
    try {
      localStorage.setItem(LS_KEY, JSON.stringify({ tuning: t, token: token }));
    } catch (e) { /* private mode / quota: tuning just will not persist */ }
  }

  // JS object -> Lua table literal. bngApi.serializeToLua is the shipped helper
  // (ui-vue/src/bridge/libs/BeamNGAPI.js); the fallback covers only the flat
  // number/boolean table we actually send.
  function toLua(obj) {
    if (typeof bngApi !== "undefined" && typeof bngApi.serializeToLua === "function") {
      return bngApi.serializeToLua(obj);
    }
    var parts = [];
    for (var k in obj) {
      var v = obj[k];
      if (typeof v === "number" && isFinite(v)) { parts.push('["' + k + '"]=' + v); }
      else if (typeof v === "boolean") { parts.push('["' + k + '"]=' + (v ? "true" : "false")); }
    }
    return "{" + parts.join(",") + "}";
  }

  // cold blue -> optimal green -> overheat red (degC)
  var TEMP_STOPS = [
    [0, 47, 105, 205], [40, 47, 165, 200], [70, 51, 185, 105],
    [75, 51, 192, 106], [100, 51, 192, 106], [120, 224, 165, 42],
    [145, 214, 69, 69], [200, 150, 24, 24]
  ];

  function rgb(stops, v) {
    if (v <= stops[0][0]) { return "rgb(" + stops[0][1] + "," + stops[0][2] + "," + stops[0][3] + ")"; }
    var last = stops[stops.length - 1];
    if (v >= last[0]) { return "rgb(" + last[1] + "," + last[2] + "," + last[3] + ")"; }
    for (var i = 1; i < stops.length; i++) {
      if (v <= stops[i][0]) {
        var a = stops[i - 1], b = stops[i];
        var f = (v - a[0]) / (b[0] - a[0]);
        return "rgb(" + Math.round(a[1] + (b[1] - a[1]) * f) + "," +
                        Math.round(a[2] + (b[2] - a[2]) * f) + "," +
                        Math.round(a[3] + (b[3] - a[3]) * f) + ")";
      }
    }
    return "rgb(255,255,255)";
  }

  function wearColor(w) {
    return rgb([[0, 51, 192, 106], [0.5, 190, 190, 60], [0.8, 224, 150, 42], [1, 214, 69, 69]], w);
  }

  return {
    template: TEMPLATE,
    replace: true,
    restrict: "EA",
    link: function (scope, element) {
      var streamsList = [STREAM];
      if (typeof StreamsManager !== "undefined") {
        StreamsManager.add(streamsList);
        scope.$on("$destroy", function () { StreamsManager.remove(streamsList); });
      }

      var root = element[0];
      var grid = root.querySelector(".atw-grid");
      var msg = root.querySelector(".atw-msg");
      var tiles = [];

      // -------------------------------------------------------------------
      // Tuning panel
      // -------------------------------------------------------------------
      var panel = root.querySelector(".atw-tune");
      var gear = root.querySelector(".atw-gear");
      var stored = loadTuning();
      var tuning = stored.tuning;
      var token = stored.token;
      var treadPct = 100;
      var sliders = {};
      var values = {};
      var buttons = {};
      var lastPushAt = 0;

      (function collect() {
        var i, el;
        var ss = panel.querySelectorAll("input[data-s]");
        for (i = 0; i < ss.length; i++) { sliders[ss[i].getAttribute("data-s")] = ss[i]; }
        var vs = panel.querySelectorAll("[data-v]");
        for (i = 0; i < vs.length; i++) { values[vs[i].getAttribute("data-v")] = vs[i]; }
        var bs = panel.querySelectorAll("[data-a]");
        for (i = 0; i < bs.length; i++) { el = bs[i]; buttons[el.getAttribute("data-a")] = el; }
      }());

      function fmt(key, v) {
        if (key === "tread") { return Math.round(v) + "%"; }
        if (key === "treadDepthNew") { return v.toFixed(1) + "mm"; }
        if (key === "sparkTreadWindow") { return v.toFixed(2) + "mm"; }
        if (key === "sparkThickness") { return v.toFixed(2); }
        return v.toFixed(2).replace(/0$/, "") + "×";
      }

      function paintPanel() {
        for (var i = 0; i < TUNING_KEYS.length; i++) {
          var k = TUNING_KEYS[i];
          sliders[k].value = tuning[k];
          values[k].textContent = fmt(k, tuning[k]);
        }
        sliders.tread.value = treadPct;
        values.tread.textContent = fmt("tread", treadPct);
        buttons.tempAffectsGrip.textContent = "TEMP AFFECTS GRIP: " + (tuning.tempAffectsGrip ? "ON" : "OFF");
        buttons.tempAffectsGrip.className = "atw-btn " + (tuning.tempAffectsGrip ? "on" : "off");
        buttons.sparksEnabled.textContent = "CORD SPARKS: " + (tuning.sparksEnabled ? "ON" : "OFF");
        buttons.sparksEnabled.className = "atw-btn " + (tuning.sparksEnabled ? "on" : "off");
      }

      // Broadcast to EVERY vehicle, so traffic and AI wear on the same rules as the
      // player. bngApi.queueAllObjectLua is a first-class bridge method and the shipped
      // Winds app uses exactly this call shape.
      function pushTuning() {
        if (typeof bngApi === "undefined") { return; }
        var payload = sanitize(tuning);
        payload.token = token;
        bngApi.queueAllObjectLua("if alexTireWear then alexTireWear.applyUserTuning(" +
          toLua(payload) + ") end");
      }

      function commitTuning() {
        token = Date.now();
        saveTuning(tuning, token);
        lastPushAt = token;
        pushTuning();
        paintPanel();
      }

      function applyTread() {
        if (typeof bngApi === "undefined") { return; }
        // Player vehicle only: "start this session on 30% tread" is about the car you
        // are driving, not about resetting the whole world's tires.
        bngApi.activeObjectLua("if alexTireWear then alexTireWear.setTreadPercent(" +
          clampNum(treadPct, 0, 100, 100) + ") end");
      }

      function onSlide(key, el, live) {
        if (key === "tread") {
          treadPct = clampNum(el.value, 0, 100, treadPct);
          values.tread.textContent = fmt("tread", treadPct);
          return;
        }
        var v = clampNum(el.value, LIMITS[key][0], LIMITS[key][1], tuning[key]);
        tuning[key] = v;
        values[key].textContent = fmt(key, v);
        // "input" fires continuously while dragging: repaint the label only, and push
        // once on "change" (mouse release / keyboard commit).
        if (!live) { commitTuning(); }
      }

      (function bind() {
        var k;
        for (k in sliders) {
          if (sliders.hasOwnProperty(k)) {
            (function (key) {
              var el = sliders[key];
              el.addEventListener("input", function () { onSlide(key, el, true); });
              el.addEventListener("change", function () { onSlide(key, el, false); });
              // do not keep keyboard focus: arrow keys would also reach the vehicle
              el.addEventListener("pointerup", function () { el.blur(); });
            }(k));
          }
        }
        buttons.applyTread.addEventListener("click", function () { applyTread(); });
        buttons.tempAffectsGrip.addEventListener("click", function () {
          tuning.tempAffectsGrip = !tuning.tempAffectsGrip;
          commitTuning();
        });
        buttons.sparksEnabled.addEventListener("click", function () {
          tuning.sparksEnabled = !tuning.sparksEnabled;
          commitTuning();
        });
        buttons.reset.addEventListener("click", function () {
          tuning = sanitize(null);
          treadPct = 100;
          commitTuning();
        });
        gear.addEventListener("click", function () {
          var open = panel.className.indexOf("open") === -1;
          panel.className = open ? "atw-tune open" : "atw-tune";
          gear.className = open ? "atw-gear on" : "atw-gear";
          if (open) { paintPanel(); }
        });
      }());

      paintPanel();

      // Two-stage placeholder, so "nothing is arriving" is distinguishable from
      // "it has not arrived yet" without digging through the console.
      var everReceived = false;   // has ANY payload ever arrived, on any vehicle?
      var waitTimer = null;

      function setMsg(text) {
        msg.textContent = text;
        msg.style.display = text ? "flex" : "none";
      }

      function armWait() {
        if (waitTimer) { $timeout.cancel(waitTimer); }
        setMsg("waiting for tire data");
        waitTimer = $timeout(function () {
          waitTimer = null;
          setMsg(everReceived ? "no tire data for this vehicle"
                              : "no data — is the mod loaded?");
        }, WAIT_MS);
      }

      function buildTiles(count) {
        grid.innerHTML = "";
        tiles = [];
        var rows = Math.max(1, Math.ceil(count / 2));
        for (var i = 0; i < count; i++) {
          var tile = document.createElement("div");
          tile.className = "atw-tile";
          tile.style.height = (100 / rows).toFixed(3) + "%";
          if (count === 1) { tile.style.width = "100%"; }
          tile.innerHTML =
            '<div class="atw-inner">' +
              '<div class="atw-fill"></div>' +
              '<div class="atw-body">' +
                '<div class="atw-row"><span class="atw-name"></span><span class="atw-temp"></span></div>' +
                '<div class="atw-depth"></div>' +
              "</div>" +
            "</div>";
          grid.appendChild(tile);
          tiles.push({
            root: tile,
            fill: tile.querySelector(".atw-fill"),
            name: tile.querySelector(".atw-name"),
            temp: tile.querySelector(".atw-temp"),
            depth: tile.querySelector(".atw-depth")
          });
        }
      }

      function reset() {
        buildTiles(0);
        armWait();
      }

      function render(list, treadNew) {
        if (list.length !== tiles.length) { buildTiles(list.length); }
        if (!list.length) {
          // The extension is alive but tracks no tires on this vehicle.
          if (waitTimer) { $timeout.cancel(waitTimer); waitTimer = null; }
          setMsg("no tires tracked on this vehicle");
          return;
        }
        if (waitTimer) { $timeout.cancel(waitTimer); waitTimer = null; }
        setMsg("");

        for (var i = 0; i < list.length; i++) {
          var d = list[i] || {};
          var t = tiles[i];
          var wear = typeof d.wear === "number" ? Math.max(0, Math.min(1, d.wear)) : 0;
          var temp = typeof d.treadTemp === "number" ? d.treadTemp : 0;
          // fall back to deriving depth from wear if an older extension omits it
          var depth = typeof d.treadDepth === "number" ? d.treadDepth : (1 - wear) * treadNew;

          t.name.textContent = d.name === undefined ? "?" : String(d.name);
          t.temp.textContent = Math.round(temp) + "°C";
          t.temp.style.color = rgb(TEMP_STOPS, temp);
          t.fill.style.height = (wear * 100) + "%";
          t.fill.style.background = wearColor(wear);

          if (d.popped) {
            t.root.className = "atw-tile atw-blown";
            t.depth.textContent = "BLOWN";
            t.depth.style.color = "#ff5a5a";
          } else {
            t.root.className = "atw-tile";
            t.depth.innerHTML = depth.toFixed(1) + '<span class="atw-unit">mm</span>';
            t.depth.style.color = wear >= 0.75 ? wearColor(wear) : "#fff";
          }
        }
      }

      scope.$on("streamsUpdate", function (event, streams) {
        var data = streams && streams[STREAM];
        if (!data) { return; }
        everReceived = true;

        // Persistence, part two. The extension echoes whichever token was last pushed
        // into it (0 on a vehicle that has never been told). Any mismatch means this
        // vehicle is running stock values -- a vehicle switch, a spawn, a Ctrl-R VM
        // reload, or a fresh game start -- so re-push. Idempotent on the Lua side, and
        // the local guard keeps us from re-pushing on every one of the 10 frames/sec.
        // Rate-limited rather than edge-triggered on purpose: an edge trigger has to
        // know when the active vehicle changed, and VehicleChange is emitted per
        // vehicle VM when its own v.data changes -- not reliably on a mere switch
        // between two already-spawned cars. Polling the token is stateless and cannot
        // get stuck, at a cost of at most one bridge call per second while mismatched.
        var vehToken = typeof data.tuningToken === "number" ? data.tuningToken : 0;
        var now = Date.now();
        if (vehToken !== token && now - lastPushAt > 1000) {
          lastPushAt = now;
          pushTuning();
        }
        var list = data.wheels;
        // an empty Lua table serialises to {} rather than [], so normalise
        if (Object.prototype.toString.call(list) !== "[object Array]") { list = []; }
        render(list, typeof data.treadNew === "number" ? data.treadNew : 8);
      });

      // Vanilla apps re-arm on these (see the shipped AdvancedWheelDebug app), and it
      // keeps a stale readout from a previous car on screen after a switch.
      scope.$on("VehicleChange", reset);
      scope.$on("VehicleReset", reset);
      scope.$on("$destroy", function () {
        if (waitTimer) { $timeout.cancel(waitTimer); waitTimer = null; }
      });

      armWait();
    }
  };
}]);
