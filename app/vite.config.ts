import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [svelte()],
  server: { proxy: { "/api": "http://localhost:4000" } },
  build: {
    outDir: "../server/priv/static",
    emptyOutDir: true,
    // Three.js is 566 kB minified (140 kB compressed) as one file, loaded
    // only when the 3D hall opens. It cannot usefully be divided further, so
    // the limit sits just above it: a warning now means something grew.
    chunkSizeWarningLimit: 600,
    rolldownOptions: {
      output: {
        // Three.js is most of the 3D scene's download and changes only when
        // its version does. In its own file, a release that changes the scene
        // does not make returning players fetch the library again.
        codeSplitting: {
          groups: [{ name: "three", test: /node_modules[\\/]three[\\/]/ }],
        },
      },
    },
  },
});
