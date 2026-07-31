import { handleAdminRequest } from "./admin.ts";

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

export default {
  async fetch(request: Request, env: AdminEnv): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/") {
        if (String(env.ADMIN_API_ENABLED) !== "true") {
          return json({ error: "Not found." }, 404);
        }
        url.pathname = "/admin/";
        return Response.redirect(url.toString(), 308);
      }

      const response = await handleAdminRequest(request, env);
      return response ?? json({ error: "Not found." }, 404);
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "Unhandled translation administration Worker error.",
          path: new URL(request.url).pathname,
          error: error instanceof Error ? error.message : String(error),
        }),
      );
      return json({ error: "Internal server error." }, 500);
    }
  },
} satisfies ExportedHandler<AdminEnv>;
