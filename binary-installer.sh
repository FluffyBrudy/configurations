#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/opt"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"

mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR"

err() { printf "Error: %s\n" "$*" >&2; exit 1; }
ask() { printf "%s" "$*" >&2; }

create_desktop_entry() {
  local name="$1"
  local exec_path="$2"
  local icon_path="${3:-}"
  local comment="${4:-}"
  local desktop_file="$DESKTOP_DIR/${name}.desktop"

  cat >"$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=${name}
Exec=${exec_path}
Terminal=false
Categories=Utility;
EOF

  if [[ -n "$comment" ]]; then
    printf "Comment=%s\n" "$comment" >>"$desktop_file"
  fi
  if [[ -n "$icon_path" ]]; then
    printf "Icon=%s\n" "$icon_path" >>"$desktop_file"
  fi

  chmod 644 "$desktop_file"
  printf "Desktop entry written to %s\n" "$desktop_file"
}

prompt_app_name() {
  local default_name="$1"
  local name=""
  ask "App name [${default_name}]: "
  read -r name
  if [[ -z "$name" ]]; then
    name="$default_name"
  fi
  printf "%s" "$name"
}

prompt_icon() {
  local app_name="$1"
  local icon=""
  local icons_dir="$HOME/.local/share/icons"
  local err_msg=""
  mkdir -p "$icons_dir"

  while true; do
    if [[ -n "$err_msg" ]]; then
      printf "%s\n" "$err_msg" >&2
      err_msg=""
    fi
    ask "Icon path or https URL (optional, Enter to skip): "
    read -r icon
    if [[ -z "$icon" ]]; then
      printf ""
      return
    fi
    if [[ "$icon" =~ ^https:// ]]; then
      local ext="png"
      if [[ "$icon" =~ \.([A-Za-z0-9]+)$ ]]; then
        ext="${BASH_REMATCH[1]}"
      fi
      local dest_icon="$icons_dir/${app_name}.${ext}"
      if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$icon" -o "$dest_icon"; then
          printf "%s" "$dest_icon"
          return
        else
          err_msg="Failed to download icon from URL."
          continue
        fi
      elif command -v wget >/dev/null 2>&1; then
        if wget -qO "$dest_icon" "$icon"; then
          printf "%s" "$dest_icon"
          return
        else
          err_msg="Failed to download icon from URL."
          continue
        fi
      else
        err_msg="curl or wget is required to download icons."
        continue
      fi
    else
      if [[ -f "$icon" ]]; then
        printf "%s" "$icon"
        return
      else
        err_msg="Icon file not found: $icon"
        continue
      fi
    fi
  done
}

prompt_exec_path() {
  local base_dir="$1"
  local exec_rel=""
  ask "Main executable (relative to ${base_dir}, or full path). Enter to skip: "
  read -r exec_rel
  if [[ -z "$exec_rel" ]]; then
    printf ""
    return
  fi
  if [[ "$exec_rel" = /* ]]; then
    printf "%s" "$exec_rel"
  else
    printf "%s" "${base_dir%/}/$exec_rel"
  fi
}
select_executable() {
  local base_dir="$1"
  local -a candidates=()
  local choice=""
  local idx=1

  while IFS= read -r -d '' file; do
    candidates+=("$file")
  done < <(find "$base_dir" -type f -executable -print0 2>/dev/null)

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    printf ""
    return
  fi

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    printf "%s" "${candidates[0]}"
    return
  fi

  printf "Multiple executables found:\n" >&2
  for file in "${candidates[@]}"; do
    printf "  %d) %s\n" "$idx" "${file#$base_dir/}" >&2
    idx=$((idx + 1))
  done
  ask "Select number (or Enter to skip): "
  read -r choice
  if [[ -z "$choice" ]]; then
    printf ""
    return
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
    printf "%s" "${candidates[$((choice - 1))]}"
    return
  fi
  err "Invalid selection."
}

ask "Path to file (.deb/.zip/.AppImage/.tar.* or binary): "
read -r INPUT_PATH
[[ -n "$INPUT_PATH" ]] || err "No path provided."

if ! FILE_PATH="$(readlink -f -- "$INPUT_PATH" 2>/dev/null)"; then
  err "Unable to resolve path."
fi
[[ -f "$FILE_PATH" ]] || err "File not found: $FILE_PATH"

FILE_NAME="$(basename -- "$FILE_PATH")"
BASE_NAME="${FILE_NAME%.*}"

lower_name="$(printf "%s" "$FILE_NAME" | tr '[:upper:]' '[:lower:]')"

case "$lower_name" in
  *.deb)
    printf "Installing .deb package...\n"
    if command -v sudo >/dev/null 2>&1; then
      if ! sudo dpkg -i "$FILE_PATH"; then
        printf "Attempting to fix dependencies...\n"
        sudo apt -f install -y
        sudo dpkg -i "$FILE_PATH"
      fi
    else
      err "sudo not available."
    fi
    ;;

  *.appimage)
    app_name="$(prompt_app_name "$BASE_NAME")"
    dest_dir="$APP_DIR/$app_name"
    mkdir -p "$dest_dir"
    dest_file="$dest_dir/$app_name.AppImage"
    cp -f -- "$FILE_PATH" "$dest_file"
    chmod +x "$dest_file"
    ln -sf "$dest_file" "$BIN_DIR/$app_name"

    icon_path="$(prompt_icon "$app_name")"
    create_desktop_entry "$app_name" "$dest_file" "$icon_path"
    printf "AppImage installed to %s and symlinked as %s\n" "$dest_file" "$BIN_DIR/$app_name"
    ;;

  *.zip)
    command -v unzip >/dev/null 2>&1 || err "unzip not found."
    app_name="$(prompt_app_name "$BASE_NAME")"
    tmp_dir="$(mktemp -d)"
    unzip -q "$FILE_PATH" -d "$tmp_dir"

    src_dir="$tmp_dir"
    if [[ "$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]] && \
       [[ "$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 0 ]]; then
      src_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    fi

    dest_dir="$APP_DIR/$app_name"
    if [[ -e "$dest_dir" ]]; then
      ask "Destination exists. Overwrite? [y/N]: "
      read -r ans
      [[ "$ans" =~ ^[Yy]$ ]] || err "Aborted."
      rm -rf "$dest_dir"
    fi
    mkdir -p "$dest_dir"
    cp -a "$src_dir"/. "$dest_dir"/
    rm -rf "$tmp_dir"

    exec_path="$(select_executable "$dest_dir")"
    if [[ -z "$exec_path" ]]; then
      exec_path="$(prompt_exec_path "$dest_dir")"
    fi
    if [[ -n "$exec_path" ]]; then
      [[ -f "$exec_path" ]] || err "Executable not found: $exec_path"
      chmod +x "$exec_path"
      ln -sf "$exec_path" "$BIN_DIR/$app_name"
      icon_path="$(prompt_icon "$app_name")"
      create_desktop_entry "$app_name" "$exec_path" "$icon_path"
      printf "Installed to %s and linked as %s\n" "$dest_dir" "$BIN_DIR/$app_name"
    else
      printf "Installed to %s (no executable linked).\n" "$dest_dir"
    fi
    ;;

  *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2)
    app_name="$(prompt_app_name "$BASE_NAME")"
    tmp_dir="$(mktemp -d)"
    tar -xf "$FILE_PATH" -C "$tmp_dir"

    src_dir="$tmp_dir"
    if [[ "$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]] && \
       [[ "$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 0 ]]; then
      src_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    fi

    dest_dir="$APP_DIR/$app_name"
    if [[ -e "$dest_dir" ]]; then
      ask "Destination exists. Overwrite? [y/N]: "
      read -r ans
      [[ "$ans" =~ ^[Yy]$ ]] || err "Aborted."
      rm -rf "$dest_dir"
    fi
    mkdir -p "$dest_dir"
    cp -a "$src_dir"/. "$dest_dir"/
    rm -rf "$tmp_dir"

    exec_path="$(select_executable "$dest_dir")"
    if [[ -z "$exec_path" ]]; then
      exec_path="$(prompt_exec_path "$dest_dir")"
    fi
    if [[ -n "$exec_path" ]]; then
      [[ -f "$exec_path" ]] || err "Executable not found: $exec_path"
      chmod +x "$exec_path"
      ln -sf "$exec_path" "$BIN_DIR/$app_name"
      icon_path="$(prompt_icon "$app_name")"
      create_desktop_entry "$app_name" "$exec_path" "$icon_path"
      printf "Installed to %s and linked as %s\n" "$dest_dir" "$BIN_DIR/$app_name"
    else
      printf "Installed to %s (no executable linked).\n" "$dest_dir"
    fi
    ;;

  *)
    app_name="$(prompt_app_name "$BASE_NAME")"
    dest_file="$BIN_DIR/$app_name"
    cp -f -- "$FILE_PATH" "$dest_file"
    chmod +x "$dest_file"
    icon_path="$(prompt_icon "$app_name")"
    create_desktop_entry "$app_name" "$dest_file" "$icon_path"
    printf "Binary installed to %s\n" "$dest_file"
    ;;
esac
