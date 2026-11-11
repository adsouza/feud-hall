import dishes1 from "./assets/stall-art/dishes-1.webp";
import dishes2 from "./assets/stall-art/dishes-2.webp";
import dishes3 from "./assets/stall-art/dishes-3.webp";
import maori from "./assets/stall-art/maori.webp";

const sheets = [
  {
    columns: 4,
    rows: 2,
    url: dishes1,
    cuisines: [
      "mughlai_punjabi",
      "sichuan",
      "levantine",
      "tamil",
      "japanese",
      "cantonese",
      "mexican",
      "persian",
    ],
  },
  {
    columns: 4,
    rows: 2,
    url: dishes2,
    cuisines: [
      "thai",
      "berber",
      "ethiopian",
      "peruvian",
      "turkish",
      "vietnamese",
      "javanese",
      "korean",
    ],
  },
  {
    columns: 4,
    rows: 2,
    url: dishes3,
    cuisines: [
      "european",
      "brazilian",
      "yoruba",
      "colombian",
      "haudenosaunee",
      "dine",
      "lakota",
      "coast_salish",
    ],
  },
  { url: maori, cuisines: ["maori"], columns: 1, rows: 1 },
];

export const cuisineArtwork = new Map(
  sheets.flatMap(({ url, cuisines, columns, rows }) =>
    cuisines.map((id, index) => [id, { url, index, columns, rows }] as const),
  ),
);
