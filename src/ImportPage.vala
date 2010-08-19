/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

#if !NO_CAMERA

class ImportSource : PhotoSource {
    protected new const string THUMBNAIL_NAME_PREFIX = "import";
    public const Gdk.InterpType INTERP = Gdk.InterpType.BILINEAR;

    private string camera_name;
    private GPhoto.Camera camera;
    private int fsid;
    private string folder;
    private string filename;
    private ulong file_size;
    private time_t modification_time;
    private PhotoFileFormat file_format;
    private Gdk.Pixbuf? preview = null;
    private string? preview_md5 = null;
    private PhotoMetadata? metadata = null;
    private string? exif_md5 = null;
    
    public ImportSource(string camera_name, GPhoto.Camera camera, int fsid, string folder, 
        string filename, ulong file_size, time_t modification_time, PhotoFileFormat file_format) {
        this.camera_name = camera_name;
        this.camera = camera;
        this.fsid = fsid;
        this.folder = folder;
        this.filename = filename;
        this.file_size = file_size;
        this.modification_time = modification_time;
        this.file_format = file_format;
    }
    
    public override string get_name() {
        string? title = get_title();
        
        return !is_string_empty(title) ? title : filename;
    }
    
    public override string to_string() {
        return "%s %s/%s".printf(camera_name, folder, filename);
    }

    public override string? get_unique_thumbnail_name() {
        return (THUMBNAIL_NAME_PREFIX + "-%" + int64.FORMAT).printf(get_object_id());
    }

    public override PhotoFileFormat get_preferred_thumbnail_format() {
        return (file_format.can_write()) ? file_format :
            PhotoFileFormat.get_system_default_format();
    }

    public override Gdk.Pixbuf? create_thumbnail(int scale) throws Error {
        if (preview == null)
            return null;
        
        // this satifies the return-a-new-instance requirement of create_thumbnail( ) because
        // scale_pixbuf( ) allocates a new pixbuf
        return (scale > 0) ? scale_pixbuf(preview, scale, INTERP, true) : preview;
    }

    // Needed because previews and exif are loaded after other information has been gathered.
    public void update(Gdk.Pixbuf? preview, string? preview_md5, PhotoMetadata? metadata, string? exif_md5) {
        this.preview = preview;
        this.preview_md5 = preview_md5;
        this.metadata = metadata;
        this.exif_md5 = exif_md5;
    }
    
    public GPhoto.Camera get_camera() {
        return camera;
    }
    
    public string get_filename() {
        return filename;
    }
    
    public string? get_fulldir() {
        return ImportPage.get_fulldir(camera, camera_name, fsid, folder);
    }
    
    public override time_t get_exposure_time() {
        if (metadata == null)
            return modification_time;
        
        MetadataDateTime? date_time = metadata.get_exposure_date_time();
        
        return (date_time != null) ? date_time.get_timestamp() : modification_time;
    }

    public override Dimensions get_dimensions() {
        if (metadata == null)
            return Dimensions(0, 0);
        
        Dimensions? dim = metadata.get_pixel_dimensions();
        if (dim == null)
            return Dimensions(0, 0);
        
        return metadata.get_orientation().rotate_dimensions(dim);
    }
    
    public string? get_title() {
        return (metadata != null) ? metadata.get_title() : null;
    }
    
    public override uint64 get_filesize() {
        return file_size;
    }
    
    public override PhotoMetadata? get_metadata() {
        return metadata;
    }
    
    public override Gdk.Pixbuf get_pixbuf(Scaling scaling) throws Error {
        return preview != null ? scaling.perform_on_pixbuf(preview, INTERP, false) : null;
    }
    
    public override Gdk.Pixbuf? get_thumbnail(int scale) throws Error {
        if (preview == null)
            return null;
        
        return (scale > 0) ? scale_pixbuf(preview, scale, INTERP, true) : preview;
    }
    
    public PhotoFileFormat get_file_format() {
        return file_format;
    }
    
    public string? get_preview_md5() {
        return preview_md5;
    }
    
    public override bool internal_delete_backing() throws Error {
        debug("Deleting %s", to_string());
        
        string? fulldir = get_fulldir();
        if (fulldir == null) {
            warning("Skipping deleting %s: invalid folder name", to_string());
            
            return true;
        }
        
        GPhoto.Result result = camera.delete_file(fulldir, get_filename(),
            ImportPage.spin_idle_context.context);
        if (result != GPhoto.Result.OK)
            warning("Error deleting %s: %s", to_string(), result.to_full_string());
        
        return result == GPhoto.Result.OK;
    }
}

class ImportPreview : CheckerboardItem {
    public const int MAX_SCALE = 128;
    
    private static Gdk.Pixbuf placeholder_preview = null;
    
    public ImportPreview(ImportSource source) {
        base(source, Dimensions(), source.get_name());
        
        // scale down pixbuf if necessary
        Gdk.Pixbuf pixbuf = null;
        try {
            pixbuf = source.get_thumbnail(0);
        } catch (Error err) {
            warning("Unable to fetch loaded import preview for %s: %s", to_string(), err.message);
        }
        
        // use placeholder if no preview available
        bool using_placeholder = (pixbuf == null);
        if (pixbuf == null) {
            if (placeholder_preview == null) {
                placeholder_preview = AppWindow.get_instance().render_icon(Gtk.STOCK_MISSING_IMAGE, 
                    Gtk.IconSize.DIALOG, null);
                placeholder_preview = scale_pixbuf(placeholder_preview, MAX_SCALE,
                    Gdk.InterpType.BILINEAR, true);
            }
            
            pixbuf = placeholder_preview;
        }
        
        // scale down if too large
        if (pixbuf.get_width() > MAX_SCALE || pixbuf.get_height() > MAX_SCALE)
            pixbuf = scale_pixbuf(pixbuf, MAX_SCALE, ImportSource.INTERP, false);

        // honor rotation
        if (!using_placeholder && source.get_metadata() != null)
            pixbuf = source.get_metadata().get_orientation().rotate_pixbuf(pixbuf);
        
        set_image(pixbuf);
    }
    
    public bool is_already_imported() {
        string? preview_md5 = get_import_source().get_preview_md5();
        PhotoFileFormat file_format = get_import_source().get_file_format();
        
        // ignore trashed duplicates
        if (!is_string_empty(preview_md5)
            && LibraryPhoto.has_nontrash_duplicate(null, preview_md5, null, file_format)) {
            return true;
        }
        
        // Because gPhoto doesn't reliably return thumbnails for RAW files, and because we want
        // to avoid downloading huge RAW files during an "import all" only to determine they're
        // duplicates, use the image's basename and filesize to do duplicate detection
        if (file_format == PhotoFileFormat.RAW) {
            uint64 filesize = get_import_source().get_filesize();
            // unlikely to be a problem, but what the hay
            if (filesize <= int64.MAX) {
                if (LibraryPhoto.global.has_basename_filesize_duplicate(
                    get_import_source().get_filename(), (int64) filesize)) {
                    return true;
                }
            }
        }
        
        return false;
    }
    
    public ImportSource get_import_source() {
        return (ImportSource) get_source();
    }
}

public class ImportPage : CheckerboardPage {
    private const string UNMOUNT_FAILED_MSG = _("Unable to unmount camera.  Try unmounting the camera from the file manager.");
    
    private class ImportViewManager : ViewManager {
        private ImportPage owner;
        
        public ImportViewManager(ImportPage owner) {
            this.owner = owner;
        }
        
        public override DataView create_view(DataSource source) {
            return new ImportPreview((ImportSource) source);
        }
    }
    
    private class CameraImportJob : BatchImportJob {
        private GPhoto.ContextWrapper context;
        private ImportSource import_file;
        private GPhoto.Camera camera;
        private string fulldir;
        private string filename;
        private uint64 filesize;
        private PhotoMetadata metadata;
        private time_t exposure_time;
        
        public CameraImportJob(GPhoto.ContextWrapper context, ImportSource import_file) {
            this.context = context;
            this.import_file = import_file;
            
            // stash everything called in prepare(), as it may/will be called from a separate thread
            camera = import_file.get_camera();
            fulldir = import_file.get_fulldir();
            // this should've been caught long ago when the files were first enumerated
            assert(fulldir != null);
            filename = import_file.get_filename();
            filesize = import_file.get_filesize();
            metadata = import_file.get_metadata();
            exposure_time = import_file.get_exposure_time();
        }
        
        public time_t get_exposure_time() {
            return exposure_time;
        }
        
        public override string get_identifier() {
            return filename;
        }
        
        public ImportSource get_source() {
            return import_file;
        }
        
        public override bool is_directory() {
            return false;
        }
        
        public override bool determine_file_size(out uint64 filesize, out File file) {
            filesize = this.filesize;
            
            return true;
        }
        
        public override bool prepare(out File file_to_import, out bool copy_to_library) throws Error {
            File dest_file = null;
            try {
                bool collision;
                dest_file = LibraryFiles.generate_unique_file(filename, metadata, exposure_time,
                    out collision);
            } catch (Error err) {
                warning("Unable to generate local file for %s: %s", import_file.get_filename(),
                    err.message);
            }
            
            if (dest_file == null) {
                message("Unable to generate local file for %s", import_file.get_filename());
                
                return false;
            }
            
            GPhoto.save_image(context.context, camera, fulldir, filename, dest_file);
            
            file_to_import = dest_file;
            copy_to_library = false;
            
            return true;
        }
    }
    
    public static GPhoto.ContextWrapper null_context = null;
    public static GPhoto.SpinIdleWrapper spin_idle_context = null;

    private SourceCollection import_sources = null;
    private Gtk.Label camera_label = new Gtk.Label(null);
    private Gtk.CheckButton hide_imported;
    private Gtk.ToolButton import_selected_button;
    private Gtk.ToolButton import_all_button;
    private Gtk.ProgressBar progress_bar = new Gtk.ProgressBar();
    private GPhoto.Camera camera;
    private string uri;
    private bool busy = false;
    private bool refreshed = false;
    private GPhoto.Result refresh_result = GPhoto.Result.OK;
    private string refresh_error = null;
    private string camera_name;
    private VolumeMonitor volume_monitor = null;
    private ImportPage? local_ref = null;
    
    public enum RefreshResult {
        OK,
        BUSY,
        LOCKED,
        LIBRARY_ERROR
    }
    
    public ImportPage(GPhoto.Camera camera, string uri) {
        base(_("Camera"));
        camera_name = _("Camera");

        this.camera = camera;
        this.uri = uri;
        this.import_sources = new SourceCollection("ImportSources for %s".printf(uri));
        
        // Mount.unmounted signal is *only* fired when a VolumeMonitor has been instantiated.
        this.volume_monitor = VolumeMonitor.get();
        
        // set up the global null context when needed
        if (null_context == null)
            null_context = new GPhoto.ContextWrapper();
        
        // same with idle-loop wrapper
        if (spin_idle_context == null)
            spin_idle_context = new GPhoto.SpinIdleWrapper();
        
        // monitor source collection to add/remove views
        get_view().monitor_source_collection(import_sources, new ImportViewManager(this), null);
        
        // sort by exposure time
        get_view().set_comparator(preview_comparator, preview_comparator_predicate);
        
        // monitor selection for UI
        get_view().items_state_changed.connect(on_view_changed);
        get_view().contents_altered.connect(on_view_changed);
        get_view().items_visibility_changed.connect(on_view_changed);
        
        // monitor Photos for removals, at that will change the result of the ViewFilter
        LibraryPhoto.global.contents_altered.connect(on_photos_added_removed);
        
        init_ui("import.ui", "/ImportMenuBar", "ImportActionGroup", create_actions(),
            create_toggle_actions());
        // Adds one menu entry per alien database driver
        AlienDatabaseHandler.get_instance().add_menu_entries(
            ui, "/ImportMenuBar/FileMenu/ImportFromAlienDbPlaceholder"
        );
        init_item_context_menu("/ImportContextMenu");
        init_page_context_menu("/ImportContextMenu");
        
        // Set up toolbar
        Gtk.Toolbar toolbar = get_toolbar();
        
        // hide duplicates checkbox
        hide_imported = new Gtk.CheckButton.with_label(_("Hide photos already imported"));
        hide_imported.set_tooltip_text(_("Only display photos that have not been imported"));
        hide_imported.clicked.connect(on_hide_imported);
        hide_imported.sensitive = false;
        hide_imported.active = false;
        Gtk.ToolItem hide_item = new Gtk.ToolItem();
        hide_item.is_important = true;
        hide_item.add(hide_imported);
        
        toolbar.insert(hide_item, -1);
        
        // separator to force buttons to right side of toolbar
        Gtk.SeparatorToolItem separator = new Gtk.SeparatorToolItem();
        separator.set_draw(false);
        
        toolbar.insert(separator, -1);
        
        progress_bar.set_orientation(Gtk.ProgressBarOrientation.LEFT_TO_RIGHT);
        progress_bar.visible = false;
        Gtk.ToolItem progress_item = new Gtk.ToolItem();
        progress_item.set_expand(true);
        progress_item.add(progress_bar);
        
        toolbar.insert(progress_item, -1);

        import_selected_button = new Gtk.ToolButton.from_stock(Resources.IMPORT);
        import_selected_button.set_label("Import Selected");
        import_selected_button.set_tooltip_text("Import the selected photos into your library");
        import_selected_button.clicked.connect(on_import_selected);
        import_selected_button.is_important = true;
        import_selected_button.sensitive = false;
        
        toolbar.insert(import_selected_button, -1);
        
        import_all_button = new Gtk.ToolButton.from_stock(Resources.IMPORT_ALL);
        import_all_button.set_label("Import All");
        import_all_button.set_tooltip_text("Import all the photos on this camera into your library");
        import_all_button.clicked.connect(on_import_all);
        import_all_button.sensitive = false;
        import_all_button.is_important = true;
        
        toolbar.insert(import_all_button, -1);
        
        GPhoto.CameraAbilities abilities;
        GPhoto.Result res = camera.get_abilities(out abilities);
        if (res != GPhoto.Result.OK) {
            debug("Unable to get camera abilities: %s", res.to_full_string());
        } else {
            camera_name = abilities.model;
            camera_label.set_text(abilities.model);
            
            set_page_name(camera_name);
        }

        // restrain the recalcitrant rascal!  prevents the progress bar from being added to the
        // show_all queue so we have more control over its visibility
        progress_bar.set_no_show_all(true);
        
        show_all();
    }
    
    ~ImportPage() {
        LibraryPhoto.global.contents_altered.disconnect(on_photos_added_removed);
    }
    
    public override string? get_icon_name() {
        return Resources.ICON_SINGLE_PHOTO;
    }

    private static int64 preview_comparator(void *a, void *b) {
        return ((ImportPreview *) a)->get_import_source().get_exposure_time()
            - ((ImportPreview *) b)->get_import_source().get_exposure_time();
    }
    
    private static bool preview_comparator_predicate(DataObject object, Alteration alteration) {
        return alteration.has_detail("metadata", "exposure-time");
    }
    
    private int64 import_job_comparator(void *a, void *b) {
        return ((CameraImportJob *) a)->get_exposure_time() - ((CameraImportJob *) b)->get_exposure_time();
    }
    
    private Gtk.ToggleActionEntry[] create_toggle_actions() {
        Gtk.ToggleActionEntry[] toggle_actions = new Gtk.ToggleActionEntry[0];

        Gtk.ToggleActionEntry titles = { "ViewTitle", null, TRANSLATABLE, "<Ctrl><Shift>T",
            TRANSLATABLE, on_display_titles, Config.get_instance().get_display_photo_titles() };
        titles.label = _("_Titles");
        titles.tooltip = _("Display the title of each photo");
        toggle_actions += titles;

        return toggle_actions;
    }

    private Gtk.ActionEntry[] create_actions() {
        Gtk.ActionEntry[] actions = new Gtk.ActionEntry[0];
        
        Gtk.ActionEntry file = { "FileMenu", null, TRANSLATABLE, null, null, on_file_menu };
        file.label = _("_File");
        actions += file;

        Gtk.ActionEntry import_selected = { "ImportSelected", Resources.IMPORT,
            TRANSLATABLE, null, null, on_import_selected };
        import_selected.label = _("Import _Selected");
        actions += import_selected;

        Gtk.ActionEntry import_all = { "ImportAll", Resources.IMPORT_ALL, TRANSLATABLE,
            null, null, on_import_all };
        import_all.label = _("Import _All");
        actions += import_all;
        
        Gtk.ActionEntry edit = { "EditMenu", null, TRANSLATABLE, null, null, on_edit_menu };
        edit.label = _("_Edit");
        actions += edit;

        Gtk.ActionEntry view = { "ViewMenu", null, TRANSLATABLE, null, null, null };
        view.label = _("_View");
        actions += view;

        Gtk.ActionEntry help = { "HelpMenu", null, TRANSLATABLE, null, null, null };
        help.label = _("_Help");
        actions += help;

        return actions;
    }
    
    public GPhoto.Camera get_camera() {
        return camera;
    }
    
    public string get_uri() {
        return uri;
    }
    
    public bool is_busy() {
        return busy;
    }
    
    public bool is_refreshed() {
        return refreshed && !busy;
    }
    
    public string? get_refresh_message() {
        string msg = null;
        if (refresh_error != null) {
            msg = refresh_error;
        } else if (refresh_result == GPhoto.Result.OK) {
            // all went well
        } else {
            msg = refresh_result.to_full_string();
        }
        
        return msg;
    }
    
    private void on_view_changed() {
        hide_imported.sensitive = !busy && refreshed && (get_view().get_unfiltered_count() > 0);
        import_selected_button.sensitive = !busy && refreshed && (get_view().get_selected_count() > 0);
        import_all_button.sensitive = !busy && refreshed && (get_view().get_count() > 0);
    }
    
    private void on_photos_added_removed() {
        get_view().reapply_view_filter();
    }

    private void on_display_titles(Gtk.Action action) {
        bool display = ((Gtk.ToggleAction) action).get_active();

        set_display_titles(display);
        Config.get_instance().set_display_photo_titles(display);
    }
    
    public override CheckerboardItem? get_fullscreen_photo() {
        error("No fullscreen support for import pages");
    }
    
    public override void switched_to() {
        set_display_titles(Config.get_instance().get_display_photo_titles());
        
        base.switched_to();
        
        try_refreshing_camera(false);
    }

    private void try_refreshing_camera(bool fail_on_locked) {
        // if camera has been refreshed or is in the process of refreshing, go no further
        if (refreshed || busy)
            return;
        
        RefreshResult res = refresh_camera();
        switch (res) {
            case ImportPage.RefreshResult.OK:
            case ImportPage.RefreshResult.BUSY:
                // nothing to report; if busy, let it continue doing its thing
                // (although earlier check should've caught this)
            break;
            
            case ImportPage.RefreshResult.LOCKED:
                if (fail_on_locked) {
                    AppWindow.error_message(UNMOUNT_FAILED_MSG);
                    
                    break;
                }
                
                // if locked because it's mounted, offer to unmount
                debug("Checking if %s is mounted ...", uri);

                File uri = File.new_for_uri(uri);

                Mount mount = null;
                try {
                    mount = uri.find_enclosing_mount(null);
                } catch (Error err) {
                    // error means not mounted
                }
                
                if (mount != null) {
                    // it's mounted, offer to unmount for the user
                    string mounted_message = _("Shotwell needs to unmount the camera from the filesystem in order to access it.  Continue?");

                    Gtk.MessageDialog dialog = new Gtk.MessageDialog(AppWindow.get_instance(), 
                        Gtk.DialogFlags.MODAL, Gtk.MessageType.QUESTION,
                        Gtk.ButtonsType.CANCEL, "%s", mounted_message);
                    dialog.title = Resources.APP_TITLE;
                    dialog.add_button(_("_Unmount"), Gtk.ResponseType.YES);
                    int dialog_res = dialog.run();
                    dialog.destroy();
                    
                    if (dialog_res != Gtk.ResponseType.YES) {
                        set_page_message(_("Please unmount the camera."));
                    } else {
                        unmount_camera(mount);
                    }
                } else {
                    string locked_message = _("The camera is locked by another application.  Shotwell can only access the camera when it's unlocked.  Please close any other application using the camera and try again.");

                    // it's not mounted, so another application must have it locked
                    Gtk.MessageDialog dialog = new Gtk.MessageDialog(AppWindow.get_instance(),
                        Gtk.DialogFlags.MODAL, Gtk.MessageType.WARNING,
                        Gtk.ButtonsType.OK, "%s", locked_message);
                    dialog.title = Resources.APP_TITLE;
                    dialog.run();
                    dialog.destroy();
                    
                    set_page_message(_("Please close any other application using the camera."));
                }
            break;
            
            case ImportPage.RefreshResult.LIBRARY_ERROR:
                AppWindow.error_message(_("Unable to fetch previews from the camera:\n%s").printf(
                    get_refresh_message()));
            break;
            
            default:
                error("Unknown result type %d", (int) res);
        }
    }
    
    public bool unmount_camera(Mount mount) {
        if (busy)
            return false;
        
        busy = true;
        refreshed = false;
        progress_bar.visible = true;
        progress_bar.set_fraction(0.0);
        progress_bar.set_ellipsize(Pango.EllipsizeMode.NONE);
        progress_bar.set_text(_("Unmounting..."));
        
        // unmount_with_operation() can/will complete with the volume still mounted (probably meaning
        // it's been *scheduled* for unmounting).  However, this signal is fired when the mount
        // really is unmounted -- *if* a VolumeMonitor has been instantiated.
        mount.unmounted.connect(on_unmounted);
        
        debug("Unmounting camera ...");
        mount.unmount_with_operation.begin(MountUnmountFlags.NONE, 
            new Gtk.MountOperation(AppWindow.get_instance()), null, on_unmount_finished);
        
        return true;
    }
    
    private void on_unmount_finished(Object? source, AsyncResult aresult) {
        debug("Async unmount finished");
        
        Mount mount = (Mount) source;
        try {
            mount.unmount_with_operation.end(aresult);
        } catch (Error err) {
            AppWindow.error_message(UNMOUNT_FAILED_MSG);
            
            // don't trap this signal, even if it does come in, we've backed off
            mount.unmounted.disconnect(on_unmounted);
            
            busy = false;
            progress_bar.set_ellipsize(Pango.EllipsizeMode.NONE);
            progress_bar.set_text("");
            progress_bar.visible = false;
        }
    }
    
    private void on_unmounted(Mount mount) {
        debug("on_unmounted");
        
        busy = false;
        progress_bar.set_ellipsize(Pango.EllipsizeMode.NONE);
        progress_bar.set_text("");
        progress_bar.visible = false;
        
        try_refreshing_camera(true);
    }
    
    private void clear_all_import_sources() {
        Marker marker = import_sources.start_marking();
        marker.mark_all();
        import_sources.destroy_marked(marker, false);
    }
    
    private RefreshResult refresh_camera() {
        if (busy)
            return RefreshResult.BUSY;
            
        refreshed = false;
        
        refresh_error = null;
        refresh_result = camera.init(spin_idle_context.context);
        if (refresh_result != GPhoto.Result.OK) {
            warning("Unable to initialize camera: %s", refresh_result.to_full_string());
            
            return (refresh_result == GPhoto.Result.IO_LOCK) ? RefreshResult.LOCKED : RefreshResult.LIBRARY_ERROR;
        }
        
        busy = true;
        
        on_view_changed();
        
        progress_bar.set_ellipsize(Pango.EllipsizeMode.NONE);
        progress_bar.set_text(_("Fetching photo information"));
        progress_bar.set_fraction(0.0);
        progress_bar.set_pulse_step(0.01);
        progress_bar.visible = true;
        
        Gee.ArrayList<ImportSource> import_list = new Gee.ArrayList<ImportSource>();
        
        GPhoto.CameraStorageInformation *sifs = null;
        int count = 0;
        refresh_result = camera.get_storageinfo(&sifs, out count, spin_idle_context.context);
        if (refresh_result == GPhoto.Result.OK) {
            for (int fsid = 0; fsid < count; fsid++) {
                if (!enumerate_files(fsid, "/", import_list))
                    break;
            }
        }
        
        clear_all_import_sources();
        load_previews(import_list);
        
        progress_bar.visible = false;
        progress_bar.set_ellipsize(Pango.EllipsizeMode.NONE);
        progress_bar.set_text("");
        progress_bar.set_fraction(0.0);
        
        GPhoto.Result res = camera.exit(spin_idle_context.context);
        if (res != GPhoto.Result.OK) {
            // log but don't fail
            warning("Unable to unlock camera: %s", res.to_full_string());
        }
        
        busy = false;
        
        if (refresh_result == GPhoto.Result.OK) {
            refreshed = true;
        } else {
            refreshed = false;
            
            // show 'em all or show none
            clear_all_import_sources();
        }
        
        on_view_changed();

        switch (refresh_result) {
            case GPhoto.Result.OK:
                return RefreshResult.OK;
            
            case GPhoto.Result.IO_LOCK:
                return RefreshResult.LOCKED;
            
            default:
                return RefreshResult.LIBRARY_ERROR;
        }
    }
    
    private static string chomp_ch(string str, char ch) {
        long offset = str.length;
        while (--offset >= 0) {
            if (str[offset] != ch)
                return str.slice(0, offset);
        }
        
        return "";
    }
    
    public static string append_path(string basepath, string addition) {
        if (!basepath.has_suffix("/") && !addition.has_prefix("/"))
            return basepath + "/" + addition;
        else if (basepath.has_suffix("/") && addition.has_prefix("/"))
            return chomp_ch(basepath, '/') + addition;
        else
            return basepath + addition;
    }
    
    // Need to do this because some phones (iPhone, in particular) changes the name of their filesystem
    // between each mount
    public static string? get_fs_basedir(GPhoto.Camera camera, int fsid) {
        GPhoto.CameraStorageInformation *sifs = null;
        int count = 0;
        GPhoto.Result res = camera.get_storageinfo(&sifs, out count, null_context.context);
        if (res != GPhoto.Result.OK)
            return null;
        
        if (fsid >= count)
            return null;
        
        GPhoto.CameraStorageInformation *ifs = sifs + fsid;
        
        return (ifs->fields & GPhoto.CameraStorageInfoFields.BASE) != 0 ? ifs->basedir : "/";
    }
    
    public static string? get_fulldir(GPhoto.Camera camera, string camera_name, int fsid, string folder) {
        if (folder.length > GPhoto.MAX_BASEDIR_LENGTH)
            return null;
        
        string basedir = get_fs_basedir(camera, fsid);
        if (basedir == null) {
            debug("Unable to find base directory for %s fsid %d", camera_name, fsid);
            
            return folder;
        }
        
        return append_path(basedir, folder);
    }

    private bool enumerate_files(int fsid, string dir, Gee.List<ImportSource> import_list) {
        string? fulldir = get_fulldir(camera, camera_name, fsid, dir);
        if (fulldir == null) {
            warning("Skipping enumerating %s: invalid folder name", dir);
            
            return true;
        }
        
        GPhoto.CameraList files;
        refresh_result = GPhoto.CameraList.create(out files);
        if (refresh_result != GPhoto.Result.OK) {
            warning("Unable to create file list: %s", refresh_result.to_full_string());
            
            return false;
        }
        
        refresh_result = camera.list_files(fulldir, files, spin_idle_context.context);
        if (refresh_result != GPhoto.Result.OK) {
            warning("Unable to list files in %s: %s", fulldir, refresh_result.to_full_string());
            
            // Although an error, don't abort the import because of this
            refresh_result = GPhoto.Result.OK;
            
            return true;
        }
        
        for (int ctr = 0; ctr < files.count(); ctr++) {
            string filename;
            refresh_result = files.get_name(ctr, out filename);
            if (refresh_result != GPhoto.Result.OK) {
                warning("Unable to get the name of file %d in %s: %s", ctr, fulldir,
                    refresh_result.to_full_string());
                
                return false;
            }
            
            try {
                GPhoto.CameraFileInfo info;
                if (!GPhoto.get_info(spin_idle_context.context, camera, fulldir, filename, out info)) {
                    warning("Skipping import of %s/%s: name too long", fulldir, filename);
                    
                    continue;
                }
                
                if ((info.file.fields & GPhoto.CameraFileInfoFields.TYPE) == 0) {
                    message("Skipping %s/%s: No file (file=%02Xh)", fulldir, filename,
                        info.file.fields);
                        
                    continue;
                }
                
                // determine file format from type, and then from file extension
                PhotoFileFormat file_format = PhotoFileFormat.from_gphoto_type(info.file.type);
                if (file_format == PhotoFileFormat.UNKNOWN) {
                    file_format = PhotoFileFormat.get_by_basename_extension(filename);
                    if (file_format == PhotoFileFormat.UNKNOWN) {
                        message("Skipping %s/%s: Not a supported file extension (%s)", fulldir,
                            filename, info.file.type);
                        
                        continue;
                    }
                }
                
                import_list.add(new ImportSource(camera_name, camera, fsid, dir, filename, 
                    info.file.size, info.file.mtime, file_format));
                
                progress_bar.pulse();
                
                // spin the event loop so the UI doesn't freeze
                if (!spin_event_loop())
                    return false;
            } catch (Error err) {
                warning("Error while enumerating files in %s: %s", fulldir, err.message);
                
                refresh_error = err.message;
                
                return false;
            }
        }
        
        GPhoto.CameraList folders;
        refresh_result = GPhoto.CameraList.create(out folders);
        if (refresh_result != GPhoto.Result.OK) {
            warning("Unable to create folder list: %s", refresh_result.to_full_string());
            
            return false;
        }
        
        refresh_result = camera.list_folders(fulldir, folders, spin_idle_context.context);
        if (refresh_result != GPhoto.Result.OK) {
            warning("Unable to list folders in %s: %s", fulldir, refresh_result.to_full_string());
            
            // Although an error, don't abort the import because of this
            refresh_result = GPhoto.Result.OK;
            
            return true;
        }
        
        for (int ctr = 0; ctr < folders.count(); ctr++) {
            string subdir;
            refresh_result = folders.get_name(ctr, out subdir);
            if (refresh_result != GPhoto.Result.OK) {
                warning("Unable to get name of folder %d: %s", ctr, refresh_result.to_full_string());
                
                return false;
            }
            
            if (!enumerate_files(fsid, append_path(dir, subdir), import_list))
                return false;
        }
        
        return true;
    }
    
    private void load_previews(Gee.List<ImportSource> import_list) {
        int loaded_photos = 0;
        foreach (ImportSource import_source in import_list) {
            string filename = import_source.get_filename();
            string? fulldir = import_source.get_fulldir();
            if (fulldir == null) {
                warning("Skipping loading preview of %s: invalid folder name", import_source.to_string());
                
                continue;
            }
            
            progress_bar.set_ellipsize(Pango.EllipsizeMode.MIDDLE);
            progress_bar.set_text(_("Fetching preview for %s").printf(import_source.get_name()));
            
            PhotoMetadata? metadata = null;
            try {
                metadata = GPhoto.load_metadata(spin_idle_context.context, camera, fulldir,
                    filename);
            } catch (Error err) {
                warning("Unable to fetch metadata for %s/%s: %s", fulldir, filename,
                    err.message);
            }
            
            // calculate EXIF's fingerprint
            string? exif_only_md5 = null;
            if (metadata != null) {
                uint8[]? flattened_sans_thumbnail = metadata.flatten_exif(false);
                if (flattened_sans_thumbnail != null && flattened_sans_thumbnail.length > 0)
                    exif_only_md5 = md5_binary(flattened_sans_thumbnail, flattened_sans_thumbnail.length);
            }
            
            // XXX: Cannot use the metadata for the thumbnail preview because libgphoto2
            // 2.4.6 has a bug where the returned EXIF data object is complete garbage.  This
            // is fixed in 2.4.7, but need to work around this as best we can.  In particular,
            // this means the preview orientation will be wrong and the MD5 is not generated
            // if the EXIF did not parse properly (see above)
            
            uint8[] preview_raw = null;
            size_t preview_raw_length = 0;
            Gdk.Pixbuf preview = null;
            try {
                preview = GPhoto.load_preview(spin_idle_context.context, camera, fulldir,
                    filename, out preview_raw, out preview_raw_length);
            } catch (Error err) {
                warning("Unable to fetch preview for %s/%s: %s", fulldir, filename, err.message);
            }
            
            // calculate thumbnail fingerprint
            string? preview_md5 = null;
            if (preview != null && preview_raw != null && preview_raw_length > 0)
                preview_md5 = md5_binary(preview_raw, preview_raw_length);
            
#if TRACE_MD5
            debug("camera MD5 %s: exif=%s preview=%s", filename, exif_only_md5, preview_md5);
#endif
            
            // update the ImportSource with the fetched information
            import_source.update(preview, preview_md5, metadata, exif_only_md5);
            
            // *now* add to the SourceCollection, now that it is completed
            import_sources.add(import_source);
            
            progress_bar.set_fraction((double) (++loaded_photos) / (double) import_list.size);
            
            // spin the event loop so the UI doesn't freeze
            if (!spin_event_loop())
                break;
        }
    }
    
    private void on_file_menu() {
        set_item_sensitive("/ImportMenuBar/FileMenu/ImportSelected", 
            !busy && (get_view().get_selected_count() > 0));
        set_item_sensitive("/ImportMenuBar/FileMenu/ImportAll", !busy && (get_view().get_count() > 0));
    }
    
    private bool show_unimported_filter(DataView view) {
        return !((ImportPreview) view).is_already_imported();
    }
    
    private void on_hide_imported() {
        if (hide_imported.get_active())
            get_view().install_view_filter(show_unimported_filter);
        else
            get_view().reset_view_filter();
    }
    
    private void on_import_selected() {
        import(get_view().get_selected());
    }
    
    private void on_import_all() {
        import(get_view().get_all());
    }
    
    private void on_edit_menu() {
        AppWindow.get_instance().set_common_action_sensitive("CommonSelectAll",
            !busy && (get_view().get_count() > 0));
    }
    
    private void import(Gee.Iterable<DataObject> items) {
        GPhoto.Result res = camera.init(spin_idle_context.context);
        if (res != GPhoto.Result.OK) {
            AppWindow.error_message(_("Unable to lock camera: %s").printf(res.to_full_string()));
            
            return;
        }
        
        busy = true;
        
        on_view_changed();
        progress_bar.visible = false;

        SortedList<CameraImportJob> jobs = new SortedList<CameraImportJob>(import_job_comparator);
        Gee.ArrayList<CameraImportJob> already_imported = new Gee.ArrayList<CameraImportJob>();
        
        foreach (DataObject object in items) {
            ImportPreview preview = (ImportPreview) object;
            ImportSource import_file = (ImportSource) preview.get_source();
            
            if (preview.is_already_imported()) {
                message("Skipping import of %s: checksum detected in library", 
                    import_file.get_filename());
                already_imported.add(new CameraImportJob(null_context, import_file));
                
                continue;
            }
            
            jobs.add(new CameraImportJob(null_context, import_file));
        }
        
        debug("Importing %d files from %s", jobs.size, camera_name);
        
        if (jobs.size > 0) {
            // see import_reporter() to see why this is held during the duration of the import
            assert(local_ref == null);
            local_ref = this;
            
            BatchImport batch_import = new BatchImport(jobs, camera_name, import_reporter,
                null, already_imported);
            batch_import.import_job_failed.connect(on_import_job_failed);
            batch_import.import_complete.connect(close_import);
            
            LibraryWindow.get_app().enqueue_batch_import(batch_import, true);
            LibraryWindow.get_app().switch_to_import_queue_page();
            // camera.exit() and busy flag will be handled when the batch import completes
        } else {
            // since failed up-front, build a fake (faux?) ImportManifest and report it here
            if (already_imported.size > 0)
                import_reporter(new ImportManifest(null, already_imported));
            
            close_import();
        }
    }
    
    private void on_import_job_failed(BatchImportResult result) {
        if (result.file == null || result.result == ImportResult.SUCCESS)
            return;
            
        // delete the copied file
        try {
            result.file.delete(null);
        } catch (Error err) {
            message("Unable to delete downloaded file %s: %s", result.file.get_path(), err.message);
        }
    }
    
    private void import_reporter(ImportManifest manifest) {
        // TODO: Need to keep the ImportPage around until the BatchImport is completed, but the
        // page controller (i.e. LibraryWindow) needs to know (a) if ImportPage is busy before
        // removing and (b) if it is, to be notified when it ain't.  Until that's in place, need
        // to hold the ref so the page isn't destroyed ... this switcheroo keeps the ref alive
        // until this function returns (at any time)
        ImportPage? local_ref = this.local_ref;
        this.local_ref = null;
        
        if (manifest.success.size > 0) {
            string question_string = (ngettext("Delete this photo from camera?",
                "Delete these %d photos from camera?", 
                manifest.success.size)).printf(manifest.success.size);
        
            ImportUI.QuestionParams question = new ImportUI.QuestionParams(
                question_string, Gtk.STOCK_DELETE, _("_Keep"));
        
            if (!ImportUI.report_manifest(manifest, false, question))
                return;
        } else {
            ImportUI.report_manifest(manifest, false, null);
            return;
        }
        
        // delete the photos from the camera and the SourceCollection... for now, this is an 
        // all-or-nothing deal
        Marker marker = import_sources.start_marking();
        foreach (BatchImportResult batch_result in manifest.success) {
            CameraImportJob job = batch_result.job as CameraImportJob;
            
            marker.mark(job.get_source());
        }
        
        ProgressDialog progress = new ProgressDialog(AppWindow.get_instance(), 
            _("Removing photos from camera"), new Cancellable());
        int error_count = import_sources.destroy_marked(marker, true, progress.monitor);
        if (error_count > 0) {
            string error_string =
                (ngettext("Unable to delete %d photo from the camera due to errors.",
                "Unable to delete %d photos from the camera due to errors.", error_count)).printf(
                error_count);
            AppWindow.error_message(error_string);
        }
        
        progress.close();
        
        // to stop build warnings
        local_ref = null;
    }

    private void close_import() {
        GPhoto.Result res = camera.exit(spin_idle_context.context);
        if (res != GPhoto.Result.OK) {
            // log but don't fail
            message("Unable to unlock camera: %s", res.to_full_string());
        }
        
        busy = false;
        
        on_view_changed();
    }

    private override void set_display_titles(bool display) {
        base.set_display_titles(display);
    
        Gtk.ToggleAction action = (Gtk.ToggleAction) action_group.get_action("ViewTitle");
        if (action != null)
            action.set_active(display);
    }

    public override bool on_context_invoked() {
        set_item_sensitive("/ImportContextMenu/ContextImportSelected", !busy &&
            get_view().get_selected_count() > 0);
        set_item_sensitive("/ImportContextMenu/ContextImportAll", !busy && 
            get_view().get_count() > 0);

        return base.on_context_invoked();
    }
}

#endif

public class ImportQueuePage : SinglePhotoPage {
    private Gtk.ToolButton stop_button = null;
    private Gee.ArrayList<BatchImport> queue = new Gee.ArrayList<BatchImport>();
    private Gee.HashSet<BatchImport> cancel_unallowed = new Gee.HashSet<BatchImport>();
    private BatchImport current_batch = null;
    private Gtk.ProgressBar progress_bar = new Gtk.ProgressBar();
    private bool stopped = false;
    
    public signal void batch_added(BatchImport batch_import);
    
    public signal void batch_removed(BatchImport batch_import);
    
    public ImportQueuePage() {
        base(_("Importing..."), false);

        init_ui("import_queue.ui", "/ImportQueueMenuBar", "ImportQueueActionGroup",
            create_actions());

        // Adds one menu entry per alien database driver
        AlienDatabaseHandler.get_instance().add_menu_entries(
            ui, "/ImportQueueMenuBar/FileMenu/ImportFromAlienDbPlaceholder"
        );
        
        // Set up toolbar
        Gtk.Toolbar toolbar = get_toolbar();
        
        // Stop button
        stop_button = new Gtk.ToolButton.from_stock(Gtk.STOCK_STOP);
        stop_button.set_tooltip_text(_("Stop importing photos"));
        stop_button.clicked.connect(on_stop);
        stop_button.sensitive = false;
        
        toolbar.insert(stop_button, -1);

        // separator to force progress bar to right side of toolbar
        Gtk.SeparatorToolItem separator = new Gtk.SeparatorToolItem();
        separator.set_draw(false);
        
        toolbar.insert(separator, -1);
        
        // Progress bar
        Gtk.ToolItem progress_item = new Gtk.ToolItem();
        progress_item.set_expand(true);
        progress_item.add(progress_bar);
        
        toolbar.insert(progress_item, -1);
    }

    private Gtk.ActionEntry[] create_actions() {
        Gtk.ActionEntry[] actions = new Gtk.ActionEntry[0];
        
        Gtk.ActionEntry file = { "FileMenu", null, TRANSLATABLE, null, null, on_file_menu };
        file.label = _("_File");
        actions += file;
        
        Gtk.ActionEntry stop = { "Stop", Gtk.STOCK_STOP, TRANSLATABLE, null, TRANSLATABLE,
            on_stop };
        stop.label = _("_Stop Import");
        stop.tooltip = _("Stop importing photos");
        actions += stop;

        Gtk.ActionEntry view = { "ViewMenu", null, TRANSLATABLE, null, null, null };
        view.label = _("_View");
        actions += view;

        Gtk.ActionEntry help = { "HelpMenu", null, TRANSLATABLE, null, null, null };
        help.label = _("_Help");
        actions += help;

        return actions;
    }
    
    public void enqueue_and_schedule(BatchImport batch_import, bool allow_user_cancel) {
        assert(!queue.contains(batch_import));
        
        batch_import.starting.connect(on_starting);
        batch_import.preparing.connect(on_preparing);
        batch_import.progress.connect(on_progress);
        batch_import.imported.connect(on_imported);
        batch_import.import_complete.connect(on_import_complete);
        batch_import.fatal_error.connect(on_fatal_error);
        
        if (!allow_user_cancel)
            cancel_unallowed.add(batch_import);
        
        queue.add(batch_import);
        batch_added(batch_import);
        
        if (queue.size == 1)
            batch_import.schedule();
        
        stop_button.sensitive = true;
    }
    
    public int get_batch_count() {
        return queue.size;
    }
    
    private void on_file_menu() {
        set_item_sensitive("/ImportQueueMenuBar/FileMenu/Stop", queue.size > 0);
    }
    
    private void on_stop() {
        if (queue.size == 0)
            return;
        
        AppWindow.get_instance().set_busy_cursor();
        stopped = true;
        
        // mark all as halted and let each signal failure
        foreach (BatchImport batch_import in queue)
            batch_import.user_halt();
    }
    
    private void on_starting(BatchImport batch_import) {
        current_batch = batch_import;
        stop_button.sensitive = !cancel_unallowed.contains(batch_import);
    }
    
    private void on_preparing() {
        progress_bar.set_text(_("Importing..."));
        progress_bar.pulse();
    }
    
    private void on_progress(uint64 completed_bytes, uint64 total_bytes) {
        double pct = (completed_bytes <= total_bytes) ? (double) completed_bytes / (double) total_bytes
            : 0.0;
        progress_bar.set_fraction(pct);
    }
    
    private void on_imported(LibraryPhoto photo, Gdk.Pixbuf pixbuf) {
        set_pixbuf(pixbuf, Dimensions.for_pixbuf(pixbuf));
        
        // set the singleton collection to this item
        get_view().clear();
        get_view().add(new PhotoView(photo));
        
        progress_bar.set_ellipsize(Pango.EllipsizeMode.MIDDLE);
        progress_bar.set_text(_("Imported %s").printf(photo.get_name()));
    }
    
    private void on_import_complete(BatchImport batch_import, ImportManifest manifest,
        BatchImportRoll import_roll) {
        assert(batch_import == current_batch);
        current_batch = null;
        
        assert(queue.size > 0);
        assert(queue.get(0) == batch_import);
        
        bool removed = queue.remove(batch_import);
        assert(removed);
        
        // fail quietly if cancel was allowed
        cancel_unallowed.remove(batch_import);
        
        // strip signal handlers
        batch_import.starting.disconnect(on_starting);
        batch_import.preparing.disconnect(on_preparing);
        batch_import.progress.disconnect(on_progress);
        batch_import.imported.disconnect(on_imported);
        batch_import.import_complete.disconnect(on_import_complete);
        batch_import.fatal_error.disconnect(on_fatal_error);
        
        // schedule next if available
        if (queue.size > 0) {
            stop_button.sensitive = true;
            queue.get(0).schedule();
        } else {
            // reset UI
            stop_button.sensitive = false;
            progress_bar.set_ellipsize(Pango.EllipsizeMode.NONE);
            progress_bar.set_text("");
            progress_bar.set_fraction(0.0);

            // blank the display
            blank_display();
            
            // reset cursor if cancelled
            if (stopped)
                AppWindow.get_instance().set_normal_cursor();
            
            stopped = false;
        }
        
        // report the batch has been removed from the queue after everything else is set
        batch_removed(batch_import);
    }
    
    private void on_fatal_error(ImportResult result, string message) {
        AppWindow.error_message(message);
    }
    
    public override string? get_icon_name() {
        return Resources.ICON_IMPORTING;
    }
}

