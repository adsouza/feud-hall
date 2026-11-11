import dishes1 from "./assets/stall-art/dishes-1.webp";
import dishes2 from "./assets/stall-art/dishes-2.webp";
import dishes3 from "./assets/stall-art/dishes-3.webp";

const sheets = [
  {
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
];

export const cuisineArtwork = new Map(
  sheets.flatMap(({ url, cuisines }) =>
    cuisines.map((id, index) => [id, { url, index }] as const),
  ),
);
