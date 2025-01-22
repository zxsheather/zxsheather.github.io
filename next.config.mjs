/** @type {import('next').NextConfig} */
const nextConfig = {
  images: {
    loader: 'imgix',
    path: '',
  },
  output: 'export', // 启用静态导出，仅适用于 GitHub Pages
  // 根据部署环境设置 assetPrefix 和 basePath
  ...(process.env.DEPLOY_ENV === 'gh-pages' && {
    assetPrefix: '/zxsheather.github.io/',
    basePath: '/zxsheather.github.io',
  }),
};

export default nextConfig;
