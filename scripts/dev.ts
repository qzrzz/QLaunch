#!/usr/bin/env bun

import { buildApp, runCommand } from "./build-app";
import { readBuildNumber, readPackageVersion } from "./version";

async function main(): Promise<void> {
  const app = await buildApp({
    configuration: "debug",
    version: readPackageVersion(),
    buildNumber: readBuildNumber(),
    productName: "QLaunchpad Dev",
    bundleIdentifier: "com.qzrzz.qlaunchpad.dev",
    signIdentity: "-",
  });

  console.log("✓ 启动 " + app.appPath);
  await runCommand([app.executablePath]);
}

main().catch((error) => {
  console.error("\n✗ " + (error instanceof Error ? error.message : error));
  process.exit(1);
});
