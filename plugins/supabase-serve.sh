# Supabase's local stack, through Docker: its hosts, and the ports
# bxn proxy NAME supabase forwards to the laptop.
PLUGIN_REQUIRES=docker
PLUGIN_EGRESS_HOSTS="supabase.com api.supabase.com mcp.supabase.com deno.land public.ecr.aws d5l0dvt14r5h8.cloudfront.net d2glxqk2uabbnd.cloudfront.net"
plugin_install() { true; }
