import { geoEqualEarth, geoGraticule10, geoPath } from "d3-geo";
import { feature } from "topojson-client";
import land from "world-atlas/land-110m.json" with { type: "json" };

// Approximate cultural locator footprints for the internal slice. Coordinates
// are longitude and latitude. They are independent of the land geometry.
const regions = {
  mughlai_punjabi: [
    [68, 25],
    [71, 32],
    [76, 34],
    [81, 31],
    [85, 26],
    [79, 23],
    [72, 23],
    [68, 25],
  ],
  sichuan: [
    [97, 27],
    [99, 32],
    [104, 34],
    [108, 31],
    [108, 27],
    [103, 26],
    [97, 27],
  ],
  levantine: [
    [34, 29],
    [34, 35],
    [36, 37],
    [40, 36],
    [40, 32],
    [37, 29],
    [34, 29],
  ],
};
const sphere = { type: "Sphere" };
const project = geoEqualEarth().fitExtent(
  [
    [12, 10],
    [628, 310],
  ],
  sphere,
);
const path = geoPath(project).digits(2);
const result = {
  outline: path(sphere),
  graticule: path(geoGraticule10()),
  land: path(feature(land, land.objects.land)),
  regions: Object.fromEntries(
    Object.entries(regions).map(([id, footprint]) => [
      id,
      path({ type: "Polygon", coordinates: [footprint] }),
    ]),
  ),
};
await Bun.write(
  new URL("../src/data/cuisine-map.json", import.meta.url),
  JSON.stringify(result, null, 2) + "\n",
);
