declare module "std:runtime" {
  export const name: "hao"
  export const namespace: "std:"

  const runtimeModule: {
    name: typeof name
    namespace: typeof namespace
  }

  export default runtimeModule
}
