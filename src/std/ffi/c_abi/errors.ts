export function invalidArg(message: string, nativeName = 'InvalidArgument'): RuntimeError {
  const error = new RuntimeError('invalid_arg', message);
  const capture = (globalThis as any).__hao_capture_native_stack;
  if (typeof capture === 'function') {
    const stack = capture(nativeName);
    if (typeof stack === 'string') (error as any).nativeStack = stack;
  }
  return error;
}

