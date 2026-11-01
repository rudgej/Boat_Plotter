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

static GtkWidget *make_button (const char *icon_name, const char *label, const char *cmd)
{
    GtkWidget *btn = gtk_button_new ();
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget *img = gtk_image_new_from_icon_name (icon_name, GTK_ICON_SIZE_DND);
    GtkWidget *lbl = gtk_label_new (label);

    gtk_box_pack_start (GTK_BOX (box), img, FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box), lbl, FALSE, FALSE, 0);
    gtk_container_add (GTK_CONTAINER (btn), box);

    g_signal_connect (btn, "clicked", G_CALLBACK (on_click), (gpointer) cmd);
    return btn;
}

int main (int argc, char **argv)
{
    gtk_init (&argc, &argv);

    GtkWidget *win = gtk_window_new (GTK_WINDOW_TOPLEVEL);
    gtk_widget_set_name (win, "pidock");

    gtk_layer_init_for_window (GTK_WINDOW (win));
    gtk_layer_set_namespace (GTK_WINDOW (win), "pi-dock");
    gtk_layer_set_layer (GTK_WINDOW (win), GTK_LAYER_SHELL_LAYER_OVERLAY);
    gtk_layer_set_anchor (GTK_WINDOW (win), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
    gtk_layer_set_anchor (GTK_WINDOW (win), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
    gtk_layer_set_exclusive_zone (GTK_WINDOW (win), 56);

    GtkCssProvider *css = gtk_css_provider_new ();
    gtk_css_provider_load_from_data (css,
        "#pidock { background-color: #ffffff; border-top: 1px solid #b0b0b0; }\n"
        "#pidock button { padding: 8px 20px; border: none; border-radius: 0; background: transparent; }\n"
        "#pidock button:hover { background: #dce8f5; }\n"
        "#pidock button:active { background: #b8d0e8; }\n"
        "#pidock label { font-size: 17px; font-weight: bold; color: #1a1a1a; }\n"
        "#pidock #powerbtn label { color: #c62828; }\n",
        -1, NULL);
    gtk_style_context_add_provider_for_screen (gdk_screen_get_default (),
        GTK_STYLE_PROVIDER (css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_container_add (GTK_CONTAINER (win), box);

    gtk_box_pack_start (GTK_BOX (box),
        make_button ("web-browser", "Signal K", "/usr/local/bin/launch-signalk.sh"),
        FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box),
        make_button ("web-browser", "Grafana", "/usr/local/bin/launch-grafana.sh"),
        FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box),
        make_button ("web-browser", "AvNav", "/usr/local/bin/launch-avnav.sh"),
        FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box),
        make_button ("web-browser", "Weather", "/usr/local/bin/launch-weather.sh"),
        FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box),
        make_button ("web-browser", "Seakeeper", "/usr/local/bin/launch-seakeeper.sh"),
        FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box),
        make_button ("web-browser", "Engine", "/usr/local/bin/launch-kip.sh"),
        FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box),
        make_button ("web-browser", "Spotify", "/usr/local/bin/launch-spotify.sh"),
        FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box),
        make_button ("bluetooth", "Bluetooth", "/usr/local/bin/bt-pair.sh"),
        FALSE, FALSE, 0);

    GtkWidget *power = make_button ("system-shutdown", "Power", "/usr/local/bin/poweroff.sh");
    gtk_widget_set_name (power, "powerbtn");
    gtk_box_pack_start (GTK_BOX (box), power, FALSE, FALSE, 0);

    gtk_widget_show_all (win);
    gtk_main ();
    return 0;
}
