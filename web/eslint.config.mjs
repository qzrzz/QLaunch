import js from "@eslint/js";
import tseslint from "typescript-eslint";

/** Vite React 工程的 TypeScript 代码检查配置。 */
export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
);
