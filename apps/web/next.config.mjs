/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The app is previewed through a proxy host. Next 15 blocks cross-origin dev asset
  // requests unless the origin is allowed here, which would break the live preview.
  allowedDevOrigins: ['*.e2b.app', 'localhost', '127.0.0.1'],
};
export default nextConfig;
