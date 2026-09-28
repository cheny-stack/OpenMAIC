/**
 * Whether browser cookies that carry credentials should use the `Secure`
 * attribute.
 *
 * Production defaults to Secure. Plain-HTTP deployments must explicitly opt
 * out with the exact value COOKIE_SECURE=0; without that, browsers discard the
 * cookie and every request is treated as unauthenticated.
 */
export function secureCookieEnabled(): boolean {
  return process.env.NODE_ENV === 'production' && process.env.COOKIE_SECURE !== '0';
}
