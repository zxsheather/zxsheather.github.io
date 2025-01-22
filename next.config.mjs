/** @type {import('next').NextConfig} */
const nextConfig = {
  assetPrefix: '/zxsheather.github.io/',
  basePath: '/zxsheather.github.io',
  images: {
    loader: 'imgix',
    path: '',
  },
  output: 'export',
};

export default nextConfig;
