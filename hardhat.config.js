import "@nomicfoundation/hardhat-toolbox";
import { subtask } from "hardhat/config.js";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names.js";
import path from "path";
import { glob } from "glob";

// Include test/mocks/ alongside src/ when compiling
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS, async (_, hre, runSuper) => {
  const paths = await runSuper();
  const mocks = await glob(
    path.join(hre.config.paths.root, "test", "mocks", "**", "*.sol")
  );
  return [...new Set([...paths, ...mocks])];
});

/** @type import('hardhat/config').HardhatUserConfig */
export default {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      evmVersion: "cancun",
    },
  },
  paths: {
    sources: "./src",
    tests: "./test",
    cache: "./cache-hardhat",
    artifacts: "./artifacts",
  },
};
