declare module "hao:plot" {
  interface TensorLike {
    readonly shape: number[]
    to_array?(): unknown
  }

  interface PlotOpts {
    color?: string
    label?: string
    lineWidth?: number
    markerSize?: number
  }

  interface BarOpts {
    color?: string
    label?: string
    width?: number
  }

  interface FigureOpts {
    width?: number
    height?: number
    title?: string
    xlabel?: string
    ylabel?: string
  }

  export function figure(opts?: FigureOpts): void
  export function title(t: string): void
  export function xlabel(l: string): void
  export function ylabel(l: string): void

  export function plot(y: TensorLike | number[], opts?: PlotOpts): void
  export function plot(x: TensorLike | number[], y: TensorLike | number[], opts?: PlotOpts): void
  export function scatter(x: TensorLike | number[], y: TensorLike | number[], opts?: PlotOpts): void
  export function bar(x: TensorLike | number[], heights: TensorLike | number[], opts?: BarOpts): void

  interface Displayable {
    repr(): { mime: string; data: string }
    toString(): string
  }

  export function show(): Displayable
  export function render(): string
  export function savefig(path: string): void

  const plotModule: {
    figure: typeof figure
    title: typeof title
    xlabel: typeof xlabel
    ylabel: typeof ylabel
    plot: typeof plot
    scatter: typeof scatter
    bar: typeof bar
    show: typeof show
    render: typeof render
    savefig: typeof savefig
  }

  export default plotModule
}
