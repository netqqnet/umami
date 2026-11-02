import { afterEach, expect, test, vi } from 'vitest';
import { request } from './fetch';

afterEach(() => vi.unstubAllGlobals());

function respond(response: Response) {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response));
}

test('preserves successful JSON and structured API errors', async () => {
  respond(Response.json({ token: 'test' }));
  expect(await request('GET', '/test')).toMatchObject({ ok: true, data: { token: 'test' } });
  const error = { error: { status: 401, code: 'incorrect-username-password' } };
  respond(Response.json(error, { status: 401 }));
  expect(await request('POST', '/test')).toEqual({ ok: false, status: 401, data: error });
});

test.each([
  [500, ''],
  [502, '<html>upstream error</html>'],
  [200, 'not JSON'],
])('handles non-JSON HTTP %i without a JSON parser exception', async (status, body) => {
  respond(new Response(body, { status }));
  const result = await request('POST', '/test');
  expect(result).toMatchObject({
    ok: false,
    status: status >= 400 ? status : 502,
    data: { error: { code: 'invalid-response' } },
  });
  expect(result.data.error.message).not.toContain(body || 'Unexpected end');
});

test('accepts a successful no-content response', async () => {
  respond(new Response(null, { status: 204 }));
  expect(await request('DELETE', '/test')).toEqual({ ok: true, status: 204 });
});
