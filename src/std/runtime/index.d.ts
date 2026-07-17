declare module "hao:runtime" {
  export const name: "hao"
  export const namespace: "hao:"

  const runtimeModule: {
    name: typeof name
    namespace: typeof namespace
  }

  export default runtimeModule
}
