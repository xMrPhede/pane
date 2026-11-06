/** esbuild's `dataurl` loader: an imported image is its own inlined `data:` URL (see build.mjs). */
declare module "*.png" {
  const url: string;
  export default url;
}
