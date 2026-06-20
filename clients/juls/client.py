# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""Thin HTTP clients for the JuLS solve API.

`JuLSClient` is synchronous; `AsyncJuLSClient` is asyncio-based and can fire many
solves concurrently with `solve_many` (the server runs them across threads). Both
wrap httpx, so the same code works for one-off scripts and high-throughput batches.
"""
from __future__ import annotations

import asyncio
from typing import Any, Iterable

import httpx

DEFAULT_BASE_URL = "http://localhost:8080"
DEFAULT_TIMEOUT = 120.0


class JuLSError(RuntimeError):
    """Raised when the server returns a non-2xx response."""


def _unwrap(resp: httpx.Response) -> dict[str, Any]:
    if resp.status_code >= 400:
        try:
            message = resp.json().get("error", resp.text)
        except Exception:
            message = resp.text
        raise JuLSError(f"HTTP {resp.status_code}: {message}")
    return resp.json()


def _payload(problem: str, data: dict, solve_opts: dict, id: Any = None) -> dict:
    payload: dict[str, Any] = {"problem": problem, "data": data}
    if id is not None:
        payload["id"] = id
    if solve_opts:
        payload["solve"] = solve_opts
    return payload


class JuLSClient:
    """Synchronous client. Use as a context manager to close the connection pool."""

    def __init__(self, base_url: str = DEFAULT_BASE_URL, timeout: float = DEFAULT_TIMEOUT):
        self._client = httpx.Client(base_url=base_url, timeout=timeout)

    def __enter__(self) -> "JuLSClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    def health(self) -> dict:
        return _unwrap(self._client.get("/health"))

    def problems(self) -> dict:
        """Registered problems and the input schema each one expects."""
        return _unwrap(self._client.get("/problems"))

    def solve(self, problem: str, data: dict, *, id: Any = None, **solve_opts: Any) -> dict:
        """Solve `problem` with `data`; keyword args (limit, using_cp, seed) form `solve`.

        Pass `id` to have the server echo it back in the response, so results can be
        matched to requests when several are in flight.
        """
        return _unwrap(self._client.post("/solve", json=_payload(problem, data, solve_opts, id)))


class AsyncJuLSClient:
    """Asyncio client. `solve_many` runs a batch of requests concurrently."""

    def __init__(self, base_url: str = DEFAULT_BASE_URL, timeout: float = DEFAULT_TIMEOUT):
        self._client = httpx.AsyncClient(base_url=base_url, timeout=timeout)

    async def __aenter__(self) -> "AsyncJuLSClient":
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    async def close(self) -> None:
        await self._client.aclose()

    async def health(self) -> dict:
        return _unwrap(await self._client.get("/health"))

    async def problems(self) -> dict:
        return _unwrap(await self._client.get("/problems"))

    async def solve(self, problem: str, data: dict, *, id: Any = None, **solve_opts: Any) -> dict:
        return _unwrap(await self._client.post("/solve", json=_payload(problem, data, solve_opts, id)))

    async def solve_many(self, requests: Iterable[dict]) -> list[dict]:
        """Solve many requests at once. Each item is {"problem", "data", "id"?, "solve"?}.

        Pass an `id` per request to match each response to its request — `solve_many`
        preserves input order, but an explicit id lets callers join results that arrive
        out of order through other paths.
        """

        async def _one(req: dict) -> dict:
            return await self.solve(req["problem"], req["data"], id=req.get("id"), **req.get("solve", {}))

        return await asyncio.gather(*(_one(req) for req in requests))
