// Realistic Tire Wear -- UI app.
// AngularJS 1.5.8 directive (the only mod-accessible UI framework in 0.38).
// Data arrives on the "alexTireWear" stream pushed by the vehicle extension.
angular.module("beamng.apps").directive("alexTireWear", [function () {
  "use strict";

  var STREAM = "alexTireWear";

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
    ".atw-wear{position:absolute;left:4px;bottom:1px;font-size:17px;font-weight:600;line-height:1}",
    ".atw-blown .atw-inner{border-color:rgba(255,90,90,0.8)}",
    ".atw-blown .atw-wear{color:#ff5a5a;font-size:13px}",
    ".atw-msg{position:absolute;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;",
    "justify-content:center;font-size:11px;opacity:0.55}"
  ].join("");

  var TEMPLATE = [
    '<div class="atw">',
    "<style>", STYLE, "</style>",
    '<div class="atw-grid"></div>',
    '<div class="atw-msg">waiting for tire data</div>',
    "</div>"
  ].join("");

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
                '<div class="atw-wear"></div>' +
              "</div>" +
            "</div>";
          grid.appendChild(tile);
          tiles.push({
            root: tile,
            fill: tile.querySelector(".atw-fill"),
            name: tile.querySelector(".atw-name"),
            temp: tile.querySelector(".atw-temp"),
            wear: tile.querySelector(".atw-wear")
          });
        }
      }

      function render(list) {
        if (list.length !== tiles.length) { buildTiles(list.length); }
        msg.style.display = list.length ? "none" : "flex";

        for (var i = 0; i < list.length; i++) {
          var d = list[i] || {};
          var t = tiles[i];
          var wear = typeof d.wear === "number" ? Math.max(0, Math.min(1, d.wear)) : 0;
          var temp = typeof d.treadTemp === "number" ? d.treadTemp : 0;

          t.name.textContent = d.name === undefined ? "?" : String(d.name);
          t.temp.textContent = Math.round(temp) + "°C";
          t.temp.style.color = rgb(TEMP_STOPS, temp);
          t.fill.style.height = (wear * 100) + "%";
          t.fill.style.background = wearColor(wear);

          if (d.popped) {
            t.root.className = "atw-tile atw-blown";
            t.wear.textContent = "BLOWN";
            t.wear.style.color = "#ff5a5a";
          } else {
            t.root.className = "atw-tile";
            t.wear.textContent = Math.round(wear * 100) + "%";
            t.wear.style.color = wear >= 0.9 ? wearColor(wear) : "#fff";
          }
        }
      }

      scope.$on("streamsUpdate", function (event, streams) {
        var data = streams && streams[STREAM];
        if (!data) { return; }
        var list = data.wheels;
        // an empty Lua table serialises to {} rather than [], so normalise
        render(Object.prototype.toString.call(list) === "[object Array]" ? list : []);
      });
    }
  };
}]);
