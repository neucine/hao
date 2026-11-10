export function invalidArg(message: string): RuntimeError {
  return new RuntimeError('invalid_arg', message);
}

