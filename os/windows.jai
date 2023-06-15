#scope_export;

copy_file :: (source: string, dest: string, silent := false) -> bool {
    source_wstr := utf8_to_wide(source);
    dest_wstr   := utf8_to_wide(dest);

    success := CopyFileW(source_wstr, dest_wstr, 0);
    if !success {
        if !silent log_error("Unable to copy file \"%\" to \"%\".\n", source, dest);
        return false;
    }

    return true;
}

// @Cleanup: Make a single heap for visit_files (allocations
// of the strings and of the array), and just free the heap
// at the end.

// @Functionality: follow_symlinks is ignored on Windows for now. I'm not sure if there is something to do there.
// But we keep it for API compatibility.
visit_files :: (dir_name: string, recursive: bool, user_data: $T, proc: (info: *File_Visit_Info, user_data: T), visit_files := true, visit_directories := false, follow_symlinks := true) -> bool {

    if !proc return true;

    directories: [..] string;
    array_add(*directories, copy_string(dir_name));
    defer {
        for directories free(it);
        array_reset(*directories);
    }

    info: File_Visit_Info = ---;
    info.is_symlink = false;
    info.had_error  = false;

    cursor := 0;
    while cursor < directories.count {
        dir_name := directories[cursor];
        cursor += 1;

        mark := get_temporary_storage_mark();
        wildcard_name := utf8_to_wide(tprint("%/*", dir_name));

        find_data: WIN32_FIND_DATAW = ---;
        handle := FindFirstFileW(wildcard_name, *find_data);

        set_temporary_storage_mark(mark);

        if handle == INVALID_HANDLE_VALUE {
            if cursor != 1  continue;

            error_value, error_string := get_error_value_and_string();
            log_error("Unable to open directory '%': % %", dir_name, error_value, error_string);
            return false;
        }

        while true {
            name := wide_to_utf8(find_data.cFileName.data, allocator=Context.default_allocator);
            full_name := join(dir_name, "/", name);  // I guess we didn't want to use temporary storage here? Do we still care about that? If so we should document why.
            defer { free(name, allocator=Context.default_allocator); free(full_name); } // Not sure why we use Context.default_allocator for name ... this is a bad thing to do as it e.g. skips Unmapping_Allocator testing.

            info.short_name             = name;
            info.full_name              = full_name;
            info.descend_into_directory = false;

            if find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY {
                if (name != ".") && (name != "..") {
                    info.descend_into_directory = recursive;
                    if visit_directories {
                        info.is_directory = true;
                        info.modification_time = filetime_to_apollo(find_data.ftLastWriteTime);
                        proc(*info, user_data);
                    }

                    if info.descend_into_directory  array_add(*directories, copy_string(full_name));
                }
            } else {
                if visit_files {
                    info.is_directory = false;
                    info.modification_time = filetime_to_apollo(find_data.ftLastWriteTime);
                    proc(*info, user_data);
                }
            }

            success := FindNextFileW(handle, *find_data);
            if !success break;
        }

        FindClose(handle);
    }

    return true;
}

file_exists :: (file_path: string) -> bool {
    // PathFileExists requires linking to shlwapi.lib, so don't use it!
    // return PathFileExistsW(utf8_to_wide(file_path)) != 0;
    return GetFileAttributesW(xx utf8_to_wide(file_path)) != INVALID_FILE_ATTRIBUTES;
}

file_modtime_and_size :: (file_path: string) -> (modtime: Apollo_Time, size: s64, success: bool) {
    h := CreateFileW(xx utf8_to_wide(file_path), 0 /*GENERIC_READ*/, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, null, OPEN_EXISTING, FILE_ATTRIBUTE_READONLY|FILE_FLAG_BACKUP_SEMANTICS, null);
    if h == INVALID_HANDLE_VALUE return .{}, 0, false;

    write_time: FILETIME;
    GetFileTime(h, null, null, *write_time);

    file_size: LARGE_INTEGER;
    ret := GetFileSizeEx(h, *file_size);

    CloseHandle(h);

    apollo := filetime_to_apollo(write_time);
    return apollo, file_size.QuadPart, ret != 0;
}

atomic_file_replace_or_just_rename_if_destination_file_does_not_exist :: (old_filename: string, new_filename: string) -> bool {
    old_filename_w := utf8_to_wide(old_filename);
    new_filename_w := utf8_to_wide(new_filename);

    attribs := GetFileAttributesW(new_filename_w);
    if attribs == INVALID_FILE_ATTRIBUTES {
        success := MoveFileW(old_filename_w, new_filename_w);
        return cast(bool) success;
    } else {
        success := ReplaceFileW(new_filename_w, old_filename_w, null, 0, null, null);
        return cast(bool) success;
    }
}

is_directory :: (path: string) -> bool, success: bool {
    attrib := GetFileAttributesW(utf8_to_wide(path));
    if attrib == INVALID_FILE_ATTRIBUTES {
        return false, false;
    }

    is_dir := (attrib & FILE_ATTRIBUTE_DIRECTORY) != 0;
    return is_dir, true;
}

#scope_file;
#import "Windows";
#import "Windows_Utf8";
#import "System";

