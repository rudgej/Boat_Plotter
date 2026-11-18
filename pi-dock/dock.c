#include <gtk/gtk.h>
#include <gtk-layer-shell.h>
#include <glib.h>

static void on_click (GtkButton *btn, gpointer data)
{
    const char *cmd = (const char *) data;
    GError *err = NULL;
    if (!g_spawn_command_line_async (cmd, &err))
    {
        g_printerr ("pi-dock: launch failed for %s: %s\n", cmd, err->message);
        g_error_free (err);
    }
}

/* Text-only button (no icon), larger label via CSS. */
static GtkWidget *make_button (const char *label, const char *cmd)
{
    GtkWidget *btn = gtk_button_new ();
    GtkWidget *lbl = gtk_label_new (label);
    gtk_container_add (GTK_CONTAINER (btn), lbl);
    g_signal_connect (btn, "clicked", G_CALLBACK (on_click), (gpointer) cmd);
    return btn;
}

/* Thin vertical divider between buttons. */
static GtkWidget *make_divider (void)
{
    GtkWidget *sep = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_name (sep, "divider");
    gtk_widget_set_size_request (sep, 2, -1);
    return sep;
}

int main (int argc, char **argv)
{
    gtk_init (&argc, &argv);

    GtkWidget *win = gtk_window_new (GTK_WINDOW_TOPLEVEL);
    gtk_widget_set_name (win, "pidock");

    gtk_layer_init_for_window (GTK_WINDOW (win));
    gtk_layer_set_namespace (GTK_WINDOW (win), "pi-dock");
    /* LAYER_TOP, not LAYER_OVERLAY: wlroots only honours an exclusive zone on
     * the TOP/BOTTOM layers. On OVERLAY the zone is ignored, the dock paints
     * over the bottom 64 px of every window, and AvNav's bottom toolbar ends up
     * hidden behind it. */
    gtk_layer_set_layer (GTK_WINDOW (win), GTK_LAYER_SHELL_LAYER_TOP);
    /* Anchor left + right so the dock spans the full screen width. */
    gtk_layer_set_anchor (GTK_WINDOW (win), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
    gtk_layer_set_anchor (GTK_WINDOW (win), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
    gtk_layer_set_anchor (GTK_WINDOW (win), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
    gtk_layer_set_exclusive_zone (GTK_WINDOW (win), 64);

    GtkCssProvider *css = gtk_css_provider_new ();
    gtk_css_provider_load_from_data (css,
        "#pidock { background-color: #ffffff; border-top: 1px solid #b0b0b0; }\n"
        "#pidock button { padding: 8px 12px; border: none; border-radius: 0; background: transparent; }\n"
        "#pidock button:hover { background: #dce8f5; }\n"
        "#pidock button:active { background: #b8d0e8; }\n"
        "#pidock label { font-size: 24px; font-weight: bold; color: #1a1a1a; }\n"
        "#pidock #divider { background: #c0c0c0; min-width: 2px; margin: 12px 0; }\n"
        "#pidock #powerbtn label { color: #c62828; }\n",
        -1, NULL);
    gtk_style_context_add_provider_for_screen (gdk_screen_get_default (),
        GTK_STYLE_PROVIDER (css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_container_add (GTK_CONTAINER (win), box);

    const char *items[][2] = {
        {"AvNav",     "/usr/local/bin/launch-avnav.sh"},
        {"Engine",    "/usr/local/bin/launch-kip.sh"},
        {"Weather",   "/usr/local/bin/launch-weather.sh"},
        {"Seakeeper", "/usr/local/bin/launch-seakeeper.sh"},
        {"Spotify",   "/usr/local/bin/launch-spotify.sh"},
        {"Signal K",  "/usr/local/bin/launch-signalk.sh"},
        {"Grafana",   "/usr/local/bin/launch-grafana.sh"},
        {"Bluetooth", "/usr/local/bin/bt-pair.sh"},
    };
    int n = sizeof (items) / sizeof (items[0]);

    for (int i = 0; i < n; i++)
    {
        gtk_box_pack_start (GTK_BOX (box), make_button (items[i][0], items[i][1]),
                            TRUE, TRUE, 0);
        gtk_box_pack_start (GTK_BOX (box), make_divider (), FALSE, FALSE, 0);
    }

    GtkWidget *power = make_button ("Power", "/usr/local/bin/poweroff.sh");
    gtk_widget_set_name (power, "powerbtn");
    gtk_box_pack_start (GTK_BOX (box), power, TRUE, TRUE, 0);

    gtk_widget_show_all (win);
    gtk_main ();
    return 0;
}
