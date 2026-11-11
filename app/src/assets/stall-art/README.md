# Stall artwork

ImageGen created these three texture atlases and the Māori illustration from dishes in the launch menus.
Each sheet is a 4-by-2 grid. [The shared artwork map](../../cuisine-artwork.ts)
maps the eight tiles in row order to stable cuisine IDs for both the 3D stalls
and the wide-screen My visit illustration. The game uses 1280×640 WebP exports
so it can load one sheet for several cuisines.

## ImageGen prompts

Each prompt combined the shared brief with one sheet's layout.

### Shared brief

```text
Use case: stylized-concept. Asset type: a single game texture atlas of eight painted food illustrations for signs on a stylized 3D food hall's stalls. Make a landscape 2:1 image with an exact grid of FOUR columns by TWO rows, eight identically sized square cells, no gutters. Every cell has the same flat warm parchment #f6e1b6 ground, including its corners, with no borders or tile outlines. The four column centers are at 12.5%, 37.5%, 62.5%, 87.5% of the image width. Row centers at 25% and 75% of image height. Draw exactly one centered and clearly recognizable dish composition in each cell, about 72% of cell width with generous blank space around it so it can be cropped by equal rectangles. Treat each dish as its own small, finished illustration in the style of hand-painted vintage market signs: bright ink and gouache, flat graphic forms with clean dark contours, three-quarter food view, enough ingredient detail to convey the dish at thumbnail scale, warm light, restrained earth tones with saturated red, green and yellow accents, minimal shadow. No words, lettering, labels, numbers, people, flags, decorative cultural symbols, grids, watermarks or mockups. Food art only.
```

### [dishes-1.webp](dishes-1.webp)

```text
Top row left to right: (1) Mughlai/Punjabi butter chicken, vivid orange curry in a small copper bowl with two blistered naan wedges; (2) Sichuan mapo tofu, cubes in red chili oil with scallion, a few red peppercorns; (3) Levantine falafel pita wrap cut to show dark falafel, green herbs and pickles, two falafel balls alongside; (4) Tamil masala dosa, a long golden crispy rolled crepe beside a small bowl of orange sambar on a banana leaf. Bottom row left to right: (1) Japanese vegetable udon, thick white noodles in a black bowl with green vegetables and chopsticks; (2) Cantonese char siu rice, neatly fanned red-edged roast pork slices over white rice; (3) Mexican bean tacos, two folded corn tortillas visibly filled with black beans, red tomato and cilantro, lime wedge; (4) Persian zereshk polo ba morgh, saffron rice dotted with vivid red barberries alongside a golden braised chicken piece.
```

### [dishes-2.webp](dishes-2.webp)

```text
Top row left to right: (1) Thai tofu pad Thai, stir-fried thin rice noodles, golden tofu, crushed peanuts and a lime wedge; (2) Amazigh chicken tagine with preserved lemon, a low terracotta tagine base with chicken and yellow preserved lemons with its distinctive terracotta conical lid tilted behind; (3) Ethiopian shiro with injera, round beige spongy injera on a platter with orange chickpea stew at center and rolled injera at side; (4) Peruvian lomo saltado, chunky beef stir fry with red onion, tomato, golden fries and a neat mound of white rice. Bottom row left to right: (1) Turkish spinach and cheese gözleme, two flat triangular grilled pastries with spinach filling showing at the cut and a small tulip glass of dark tea; (2) Vietnamese tofu bánh mì, a split crisp baguette brimming with tofu, orange carrot, pale daikon and cilantro; (3) Javanese chicken satay, several charred skewers and a small bowl of peanut sauce on a deep green banana leaf; (4) Korean vegetable bibimbap, black bowl with rice and bright separate wedges of greens, carrot, sprouts and mushrooms with red chili paste at center.
```

### [dishes-3.webp](dishes-3.webp)

```text
Top row left to right: (1) European tomato pasta, a white plate of tomato-red spaghetti with basil leaves; (2) Brazilian moqueca de peixe, a black clay bowl of golden fish stew with red peppers and a small mound of white rice; (3) Yoruba ewa riro with plantain, bowl of orange-brown stewed cowpeas with a fan of golden fried plantain slices; (4) Colombian arepa con queso, two round griddled golden corn cakes, one split to show white cheese. Bottom row left to right: (1) Haudenosaunee Three Sisters soup, bowl of white corn kernels, red beans and orange squash in broth with those three ingredients shown beside it; (2) Diné blue-corn griddle cakes, a stack of round blue-purple corn cakes beside a few roasted orange squash wedges; (3) Lakota cedar-braised bison, dark sliced braised bison with wild onions; (4) Coast Salish roasted salmon, vivid orange char-roasted salmon fillet with dark skin on a simple plate. Represent these cuisines by the plated foods, with no cultural motifs or ceremonial objects.
```

### [maori.webp](maori.webp)

The Māori boil-up is a standalone 512×512 tile. The shared map records each
sheet's columns/rows, so the renderer and My visit can use both atlas tiles and
standalone illustrations. Generated with the built-in imagegen tool; the PNG
master remains in the local generated-image library, and this WebP is the game
asset.

```text
Use case: stylized-concept. Asset type: square food illustration for the Māori cuisine stall in Feud Hall, matching hand-painted vintage market food signs. Create ONE square illustration of a generous Māori pork-and-pūhā boil-up: a simple deep ceramic bowl of warm clear golden broth with chunky tender pork, leafy green pūhā (sow thistle), a few orange kūmara sweet-potato pieces, and two pale flour dumplings. Three-quarter food view, recognizable ingredients, bright ink and gouache with clean dark contours, warm light, restrained earth tones with saturated greens and orange accents, minimal shadow. Composition centered within about 75% of the square, generous blank margin on all sides, flat warm parchment #f6e1b6 background filling every corner. No lettering, text, labels, people, flags, cultural motifs, carvings, ceremonial objects, watermarks, borders or mockups. Food art only, appetizing and readable at thumbnail size.
```
