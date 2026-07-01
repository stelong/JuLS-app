# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""Thin HTTP clients for the JuLS solve API.

`JuLSClient` is synchronous; `AsyncJuLSClient` is asyncio-based and can fire many
solves concurrently with `solve_many` (the server runs them across threads). Both
wrap httpx, so the same code works for one-off scripts and high-throughput batches.

Both cover the full server surface: `health`/`ready`/`problems`/`metrics`, the
synchronous `solve`, and the asynchronous job API (`submit_job`/`job`, plus a
`solve_async` convenience that submits then polls to completion). Pass `api_key` to
authenticate when the server has `JULS_API_KEY` set.
"""
from __future__ import annotations

import asyncio
import time
from typing import Any, Iterable

import httpx

DEFAULT_BASE_URL = "http://localhost:8080"
DEFAULT_TIMEOUT = 120.0
DEFAULT_POLL_INTERVAL = 0.5
DEFAULT_POLL_TIMEOUT = 600.0
DEFAULT_MAX_RETRIES = 5
_RETRY_BACKOFF = 0.25  # initial backoff (s) when the server sends no Retry-After

#: Job states in which no further change will occur.
TERMINAL_STATES = frozenset({"succeeded", "failed", "timed_out"})


class JuLSError(RuntimeError):
    """Raised when the server returns a non-2xx response."""


def _retry_after(resp: httpx.Response, fallback: float) -> float:
    """Seconds to wait before retrying a 429, from the `Retry-After` header if present."""
    value = resp.headers.get("Retry-After")
    if value is None:
        return fallback
    try:
        return max(0.0, float(value))
    except ValueError:
        return fallback


def _unwrap(resp: httpx.Response) -> dict[str, Any]:
    if resp.status_code >= 400:
        try:
            message = resp.json().get("error", resp.text)
        except Exception:
            message = resp.text
        raise JuLSError(f"HTTP {resp.status_code}: {message}")
    return resp.json()


def _unwrap_text(resp: httpx.Response) -> str:
    if resp.status_code >= 400:
        raise JuLSError(f"HTTP {resp.status_code}: {resp.text}")
    return resp.text


def _payload(problem: str, data: dict, solve_opts: dict, id: Any = None) -> dict:
    payload: dict[str, Any] = {"problem": problem, "data": data}
    if id is not None:
        payload["id"] = id
    if solve_opts:
        payload["solve"] = solve_opts
    return payload


def _headers(api_key: str | None) -> dict[str, str] | None:
    return {"X-API-Key": api_key} if api_key else None


class JuLSClient:
    """Synchronous client. Use as a context manager to close the connection pool."""

    def __init__(
        self,
        base_url: str = DEFAULT_BASE_URL,
        timeout: float = DEFAULT_TIMEOUT,
        api_key: str | None = None,
        max_retries: int = DEFAULT_MAX_RETRIES,
    ):
        self._client = httpx.Client(base_url=base_url, timeout=timeout, headers=_headers(api_key))
        self._max_retries = max_retries

    def __enter__(self) -> "JuLSClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    # -- probes & introspection ------------------------------------------------
    def health(self) -> dict:
        return _unwrap(self._client.get("/health"))

    def ready(self) -> bool:
        """True once the server has warmed up (`GET /ready`); False while starting."""
        resp = self._client.get("/ready")
        if resp.status_code == 503:
            return False
        _unwrap(resp)
        return True

    def problems(self) -> dict:
        """Registered problems and the input schema each one expects."""
        return _unwrap(self._client.get("/problems"))

    def metrics(self) -> str:
        """Raw Prometheus exposition text (`GET /metrics`)."""
        return _unwrap_text(self._client.get("/metrics"))

    # -- synchronous solve -----------------------------------------------------
    def solve(self, problem: str, data: dict, *, id: Any = None, **solve_opts: Any) -> dict:
        """Solve `problem` with `data`; keyword args (limit, using_cp, seed) form `solve`.

        This call blocks until the solve finishes and returns the result. `id` is an
        optional correlation label — echoed back and included in the server logs for
        tracing; it is not needed to retrieve results (use `/jobs` for async polling).

        Transparently retries on HTTP 429 (server at its concurrency cap), honoring
        `Retry-After`, up to the client's `max_retries`.
        """
        payload = _payload(problem, data, solve_opts, id)
        backoff = _RETRY_BACKOFF
        for attempt in range(self._max_retries + 1):
            resp = self._client.post("/solve", json=payload)
            if resp.status_code == 429 and attempt < self._max_retries:
                time.sleep(_retry_after(resp, backoff))
                backoff = min(backoff * 2, 5.0)
                continue
            return _unwrap(resp)
        return _unwrap(resp)  # retries exhausted: raise the last 429

    # -- asynchronous jobs -----------------------------------------------------
    def submit_job(self, problem: str, data: dict, *, id: Any = None, **solve_opts: Any) -> dict:
        """Submit an async solve (`POST /jobs`); returns `{job_id, status, poll}`."""
        return _unwrap(self._client.post("/jobs", json=_payload(problem, data, solve_opts, id)))

    def job(self, job_id: str) -> dict:
        """Fetch an async job's status/result (`GET /jobs/{id}`)."""
        return _unwrap(self._client.get(f"/jobs/{job_id}"))

    def solve_async(
        self,
        problem: str,
        data: dict,
        *,
        id: Any = None,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        poll_timeout: float = DEFAULT_POLL_TIMEOUT,
        **solve_opts: Any,
    ) -> dict:
        """Submit a job and poll until it finishes, returning the final job record.

        Returns the job dict once `status` is `succeeded` or `timed_out` (which carries
        the best solution found). Raises `JuLSError` if the job fails, or `TimeoutError`
        if it doesn't finish within `poll_timeout` seconds.
        """
        job_id = self.submit_job(problem, data, id=id, **solve_opts)["job_id"]
        deadline = time.monotonic() + poll_timeout
        while True:
            status = self.job(job_id)
            if status["status"] in TERMINAL_STATES:
                if status["status"] == "failed":
                    raise JuLSError(f"job {job_id} failed: {status.get('error')}")
                return status
            if time.monotonic() > deadline:
                raise TimeoutError(f"job {job_id} did not finish within {poll_timeout}s")
            time.sleep(poll_interval)


class AsyncJuLSClient:
    """Asyncio client. `solve_many` runs a batch of requests concurrently."""

    def __init__(
        self,
        base_url: str = DEFAULT_BASE_URL,
        timeout: float = DEFAULT_TIMEOUT,
        api_key: str | None = None,
        max_retries: int = DEFAULT_MAX_RETRIES,
    ):
        self._client = httpx.AsyncClient(base_url=base_url, timeout=timeout, headers=_headers(api_key))
        self._max_retries = max_retries

    async def __aenter__(self) -> "AsyncJuLSClient":
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    async def close(self) -> None:
        await self._client.aclose()

    # -- probes & introspection ------------------------------------------------
    async def health(self) -> dict:
        return _unwrap(await self._client.get("/health"))

    async def ready(self) -> bool:
        resp = await self._client.get("/ready")
        if resp.status_code == 503:
            return False
        _unwrap(resp)
        return True

    async def problems(self) -> dict:
        return _unwrap(await self._client.get("/problems"))

    async def metrics(self) -> str:
        return _unwrap_text(await self._client.get("/metrics"))

    # -- synchronous solve -----------------------------------------------------
    async def solve(self, problem: str, data: dict, *, id: Any = None, **solve_opts: Any) -> dict:
        """Solve one request; retries on HTTP 429 honoring `Retry-After` (see `JuLSClient.solve`)."""
        payload = _payload(problem, data, solve_opts, id)
        backoff = _RETRY_BACKOFF
        for attempt in range(self._max_retries + 1):
            resp = await self._client.post("/solve", json=payload)
            if resp.status_code == 429 and attempt < self._max_retries:
                await asyncio.sleep(_retry_after(resp, backoff))
                backoff = min(backoff * 2, 5.0)
                continue
            return _unwrap(resp)
        return _unwrap(resp)  # retries exhausted: raise the last 429

    async def solve_many(self, requests: Iterable[dict]) -> list[dict]:
        """Solve many requests at once. Each item is {"problem", "data", "id"?, "solve"?}.

        This is *client-side* concurrency over the synchronous `/solve` (each request
        still blocks server-side until done) — good for many short solves. Results are
        returned in input order; the optional per-request `id` is just a correlation
        label. For long solves that shouldn't hold a connection open, use `/jobs`.
        """

        async def _one(req: dict) -> dict:
            return await self.solve(req["problem"], req["data"], id=req.get("id"), **req.get("solve", {}))

        return await asyncio.gather(*(_one(req) for req in requests))

    # -- asynchronous jobs -----------------------------------------------------
    async def submit_job(self, problem: str, data: dict, *, id: Any = None, **solve_opts: Any) -> dict:
        return _unwrap(await self._client.post("/jobs", json=_payload(problem, data, solve_opts, id)))

    async def job(self, job_id: str) -> dict:
        return _unwrap(await self._client.get(f"/jobs/{job_id}"))

    async def solve_async(
        self,
        problem: str,
        data: dict,
        *,
        id: Any = None,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        poll_timeout: float = DEFAULT_POLL_TIMEOUT,
        **solve_opts: Any,
    ) -> dict:
        """Submit a job and poll until it finishes (see `JuLSClient.solve_async`)."""
        submitted = await self.submit_job(problem, data, id=id, **solve_opts)
        job_id = submitted["job_id"]
        deadline = time.monotonic() + poll_timeout
        while True:
            status = await self.job(job_id)
            if status["status"] in TERMINAL_STATES:
                if status["status"] == "failed":
                    raise JuLSError(f"job {job_id} failed: {status.get('error')}")
                return status
            if time.monotonic() > deadline:
                raise TimeoutError(f"job {job_id} did not finish within {poll_timeout}s")
            await asyncio.sleep(poll_interval)
