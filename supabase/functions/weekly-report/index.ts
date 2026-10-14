// Emails the UMANG traffic and orders report to commsteam@yojak.org.
// Deploy:  supabase functions deploy weekly-report --no-verify-jwt
// Secrets: supabase secrets set RESEND_API_KEY=... CRON_SECRET=... REPORT_FROM="UMANG Reports <reports@yourdomain.org>"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TO = "commsteam@yojak.org";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-cron-secret",
};
const esc = (v: unknown) => String(v ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const inr = (n: number) => "₹" + Number(n || 0).toLocaleString("en-IN");
const delta = (a: number, b: number) => (b ? `${a >= b ? "▲" : "▼"} ${Math.abs(Math.round(((a - b) / b) * 100))}% vs previous` : "no previous data");

const table = (title: string, head: string[], rows: unknown[][]) =>
  `<h3 style="margin:22px 0 6px;color:#321936">${esc(title)}</h3><table style="border-collapse:collapse;width:100%;font-size:14px"><tr>${head
    .map((h) => `<th style="text-align:left;padding:6px 8px;background:#E9E7FF">${esc(h)}</th>`)
    .join("")}</tr>${
    rows.length
      ? rows.map((r) => `<tr>${r.map((c) => `<td style="padding:6px 8px;border-bottom:1px solid #E5DFE1">${esc(c)}</td>`).join("")}</tr>`).join("")
      : `<tr><td colspan="${head.length}" style="padding:6px 8px">No data yet</td></tr>`
  }</table>`;

const kpi = (label: string, value: string, note = "") =>
  `<td style="background:#fff;border:1px solid #E5DFE1;border-radius:10px;padding:12px;text-align:center"><div style="font-size:24px;font-weight:700;color:#5A299C">${esc(value)}</div><div style="font-size:13px;color:#533A58">${esc(label)}</div><div style="font-size:11px;color:#533A58">${esc(note)}</div></td>`;

function build(r: any) {
  const f = r.funnel;
  return `<div style="font-family:Georgia,serif;max-width:680px;margin:auto;color:#321936;background:#FCF9FF;padding:20px">
  <h2 style="margin:0">UMANG Products report</h2><p style="margin:4px 0 16px;color:#533A58">Last ${r.days} days · Powered &amp; backed by YOJAK</p>
  <table style="width:100%;border-spacing:8px"><tr>${kpi("Visitors", String(r.visitors), delta(r.visitors, r.visitors_prev))}${kpi("Orders", String(r.orders), delta(r.orders, r.orders_prev))}${kpi("Order value", inr(r.order_value), "indicative")}</tr>
  <tr>${kpi("New supporters", String(r.supporters), `${r.supporters_total} in total`)}${kpi("Reviewers", String(r.reviewers), `${r.reviews_approved} approved`)}${kpi("Page views", String(r.page_views), `${r.sessions} sessions`)}</tr></table>
  ${table("Funnel (unique visitors)", ["Step", "Visitors"], [["Visited", f.visitors], ["Viewed a product", f.viewed_product], ["Added to bag", f.added], ["Started checkout", f.checkout], ["Placed an order", f.ordered]])}
  ${table("Most ordered", ["Product", "Qty", "Value"], (r.top_ordered || []).map((x: any) => [x.name || x.id, x.qty, inr(x.value)]))}
  ${table("Most added to bag", ["Product", "Qty"], (r.top_added || []).map((x: any) => [x.name || x.product_id, x.qty]))}
  ${table("Most viewed products", ["Product", "Views"], (r.top_viewed || []).map((x: any) => [x.name || x.product_id, x.views]))}
  ${table("Top pages", ["Page", "Views", "Visitors"], (r.top_pages || []).map((x: any) => [x.page, x.views, x.visitors]))}
  ${table("Orders by city", ["City", "State", "Orders"], (r.cities || []).map((x: any) => [x.city, x.state, x.orders]))}
  ${table("Traffic sources", ["Source", "Visitors"], (r.sources || []).map((x: any) => [x.src, x.visitors]))}
  ${table("Devices", ["Device", "Visitors"], (r.devices || []).map((x: any) => [x.device || "unknown", x.visitors]))}
  <p style="font-size:12px;color:#533A58;margin-top:24px">Visitors are counted anonymously. Names, phone numbers and addresses are not part of analytics.</p></div>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const body = await req.json().catch(() => ({}));
  const days = Math.min(90, Math.max(1, Number(body.days) || 7));

  // Allowed callers: the weekly schedule (secret header) or the signed-in YOJAK admin.
  const secret = req.headers.get("x-cron-secret");
  let ok = !!secret && secret === Deno.env.get("CRON_SECRET");
  if (!ok) {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (token) {
      const { data } = await sb.auth.getUser(token);
      const email = (data?.user?.email || "").toLowerCase();
      if (email) {
        const { data: a } = await sb.from("admins").select("role").eq("email", email).maybeSingle();
        ok = a?.role === "yojak"; // the UMANG admin cannot trigger or receive this report
      }
    }
  }
  if (!ok) return new Response("Forbidden", { status: 403, headers: cors });

  const { data: report, error } = await sb.rpc("report_json", { p_days: days });
  if (error) return new Response(error.message, { status: 500, headers: cors });

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: Deno.env.get("REPORT_FROM") || "UMANG Reports <onboarding@resend.dev>",
      to: [TO],
      subject: `UMANG Products report: last ${days} days`,
      html: build(report),
    }),
  });
  return new Response(await res.text(), { status: res.ok ? 200 : 502, headers: cors });
});
