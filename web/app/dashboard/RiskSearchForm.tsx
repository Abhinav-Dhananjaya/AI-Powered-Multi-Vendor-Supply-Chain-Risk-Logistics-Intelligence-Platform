"use client";
// app/dashboard/RiskSearchForm.tsx — client component calling /api/risk-search
import { useState, FormEvent } from "react";

interface Hit {
  doc_id: number;
  doc_type: "Contract" | "News";
  title: string;
  supplier: string | null;
  similarity: number;
  snippet: string;
}

export default function RiskSearchForm() {
  const [query, setQuery] = useState("");
  const [docType, setDocType] = useState("");
  const [hits, setHits] = useState<Hit[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    try {
      const res = await fetch("/api/risk-search", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query, limit: 5, docType: docType || undefined }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error ?? "Search failed");
      setHits(data.results);
    } catch (err) {
      setError((err as Error).message);
      setHits(null);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="space-y-4">
      <form onSubmit={onSubmit} className="flex flex-col gap-3 sm:flex-row">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder='e.g. "port strike delays in Europe" or "late delivery penalty clause"'
          className="flex-1 rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
          minLength={3}
          required
        />
        <select
          value={docType}
          onChange={(e) => setDocType(e.target.value)}
          className="rounded-md border border-slate-300 px-3 py-2 text-sm"
          aria-label="Document type"
        >
          <option value="">All documents</option>
          <option value="Contract">Contracts</option>
          <option value="News">News</option>
        </select>
        <button
          disabled={loading}
          className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500 disabled:opacity-50"
        >
          {loading ? "Searching…" : "Search"}
        </button>
      </form>

      {error && <p className="rounded-md bg-red-50 p-3 text-sm text-red-700">{error}</p>}

      {hits && (
        <ul className="space-y-3">
          {hits.length === 0 && <li className="text-sm text-slate-500">No matching documents.</li>}
          {hits.map((h) => (
            <li key={h.doc_id} className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="font-medium text-slate-900">{h.title}</p>
                  <p className="text-xs text-slate-500">
                    {h.doc_type}{h.supplier ? ` · ${h.supplier}` : ""}
                  </p>
                </div>
                <span className="shrink-0 rounded-full bg-indigo-50 px-2.5 py-0.5 text-xs font-medium text-indigo-700">
                  {(h.similarity * 100).toFixed(1)}% match
                </span>
              </div>
              <p className="mt-2 text-sm text-slate-600">{h.snippet}…</p>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
