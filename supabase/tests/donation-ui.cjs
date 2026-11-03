// Preserve the existing smoke-test entry point without browser dependencies.
// The member donation screen now intentionally blocks sandbox checkout.
import('./live-donation-frontend.test.mjs').catch(error=>{console.error(error);process.exitCode=1});
