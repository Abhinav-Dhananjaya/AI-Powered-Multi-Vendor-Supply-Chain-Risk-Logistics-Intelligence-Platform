// app/dashboard/page.tsx — Server Component: Supplier Risk Summary + semantic Risk Search
import { redirect } from "next/navigation";
import { pool } from "@/lib/db";
import { getSession, can } from "@/lib/auth";
import RiskSearchForm from "./RiskSearchForm";

export const dynamic = "force-dynamic";

interface SupplierRow {
  supplier_id: number;
  name: string;
  country: string;
  tier: number;
  total_orders: number;
  total_spend: string;
  total_shipments: number;
  delayed_shipments: number;
  delay_rate_pct: string | null;
  avg_delay_days: string;
  risk_score: string;
  risk_level: "Low" | "Medium" | "High";
}

const badge: Record<SupplierRow["risk_level"], string> = {
  Low: "bg-emerald-100 text-emerald-800 ring-emerald-600/20",
  Medium: "bg-amber-100 text-amber-800 ring-amber-600/20",
  High: "bg-red-100 text-red-800 ring-red-600/20",
};

export default async function DashboardPage() {
  const session = await getSession();
  if (!session) redirect("/login");
  if (!can(session, "risk:read")) {
    return (
      <main className="p-8">
        <p className="rounded-md bg-red-50 p-4 text-red-700">
          Your role ({session.role}) cannot view supplier risk data.
        </p>
      </main>
    );
  }

  const { rows } = await pool.query<SupplierRow>(
    `SELECT * FROM vw_supplier_risk_summary ORDER BY risk_score DESC, name`
  );

  return (
    <main className="mx-auto max-w-6xl space-y-10 p-6 md:p-10">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-slate-900">Supply Chain Risk Dashboard</h1>
          <p className="text-sm text-slate-500">Signed in as {session.email} · {session.role}</p>
        </div>
      </header>

      <section>
        <h2 className="mb-3 text-lg font-medium text-slate-800">Supplier risk summary</h2>
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm">
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50 text-left text-xs font-semibold uppercase tracking-wide text-slate-600">
              <tr>
                <th className="px-4 py-3">Supplier</th>
                <th className="px-4 py-3">Country</th>
                <th className="px-4 py-3 text-right">Orders</th>
                <th className="px-4 py-3 text-right">Spend</th>
                <th className="px-4 py-3 text-right">Shipments</th>
                <th className="px-4 py-3 text-right">Delay rate</th>
                <th className="px-4 py-3 text-right">Avg days late</th>
                <th className="px-4 py-3 text-right">Risk score</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={r.supplier_id} className="hover:bg-slate-50">
                  <td className="px-4 py-3 font-medium text-slate-900">
                    {r.name} <span className="ml-1 text-xs text-slate-400">T{r.tier}</span>
                  </td>
                  <td className="px-4 py-3 text-slate-600">{r.country}</td>
                  <td className="px-4 py-3 text-right tabular-nums">{r.total_orders}</td>
                  <td className="px-4 py-3 text-right tabular-nums">
                    {Number(r.total_spend).toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 })}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums">{r.total_shipments}</td>
                  <td className="px-4 py-3 text-right tabular-nums">
                    {r.delay_rate_pct === null ? "—" : `${r.delay_rate_pct}%`}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums">{r.avg_delay_days}</td>
                  <td className="px-4 py-3 text-right">
                    <span className={`inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset ${badge[r.risk_level]}`}>
                      {r.risk_score} · {r.risk_level}
                    </span>
                  </td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr><td colSpan={8} className="px-4 py-8 text-center text-slate-500">No suppliers found.</td></tr>
              )}
            </tbody>
          </table>
        </div>
        <p className="mt-2 text-xs text-slate-400">
          Data from materialized view <code>vw_supplier_risk_summary</code> (refresh it after new shipments).
        </p>
      </section>

      <section>
        <h2 className="mb-3 text-lg font-medium text-slate-800">Semantic risk search</h2>
        <RiskSearchForm />
      </section>
    </main>
  );
}
