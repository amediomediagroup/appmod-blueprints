/** @type {import('next').NextConfig} */
module.exports = {
  eslint: {
    // Disabling on production builds because we're running checks on PRs via GitHub Actions.
    ignoreDuringBuilds: true
  },
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: 'd2pxm7bxcihgvo.cloudfront.net',
        pathname: '/**'
      }
    ]
  },
  output: "standalone",
  assetPrefix: "/unicorn",
  basePath: '/unicorn',
};
