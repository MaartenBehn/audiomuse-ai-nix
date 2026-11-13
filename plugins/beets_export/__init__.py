import html
import os
import subprocess
import logging
from flask import Blueprint, request, redirect, url_for
from plugin.api import get_db, table, render_page

logger = logging.getLogger("audiomuse.plugins.beets_export")

bp = Blueprint('beets_export', __name__)

MUSIC_BASE_DIR = "/media/music"

# Minimum score threshold for mood/feature tags to be included in exports.
# Tags (from mood_vector and other_features) with a score below this value are dropped.
# Up to 3 tags meeting this threshold are kept (sorted by score descending).
MOOD_MIN_SCORE = float(os.environ.get("MOOD_MIN_SCORE", "0.6"))

# Fallback threshold: if no tags meet MOOD_MIN_SCORE, the single best tag is used
# only if its score is at least this value.
MOOD_FALLBACK_SCORE = float(os.environ.get("MOOD_FALLBACK_SCORE", "0.4"))

def migrate(db):
    """Creates the sync audit log table on plugin installation."""
    try:
        cur = db.cursor()
        sync_log = table('beets_sync_log')
        cur.execute(
            "CREATE TABLE IF NOT EXISTS " + sync_log +
            " (id SERIAL PRIMARY KEY, audio_path TEXT, bpm REAL, mood TEXT, synced_at TEXT, status TEXT, error TEXT)"
        )
        db.commit()
        cur.close()
    except Exception as e:
        db.rollback()
        logger.exception("Migration failed for beets_sync_log table")
        raise

def _parse_tag_scores(val) -> list[tuple[str, float | None]]:
    """Parses a tag value into a list of (tag, score) tuples.

    Accepts dicts, 'tag:score,...' strings, plain 'tag,tag,...' strings, and
    Python lists of plain tag strings.  Tags without a meaningful score are
    returned with ``score=None`` so callers can distinguish them from tags
    that were explicitly scored zero.
    """
    if not val:
        return []
    if isinstance(val, dict):
        try:
            return [(str(k).strip(), float(v)) for k, v in val.items()]
        except Exception:
            return [(str(k).strip(), None) for k in val.keys()]
    if isinstance(val, list):
        res = []
        for t in val:
            if isinstance(t, dict):
                name = t.get('name') or t.get('tag') or t.get('mood')
                if name:
                    score = t.get('score')
                    try:
                        res.append((str(name).strip(), float(score) if score is not None else None))
                    except (ValueError, TypeError):
                        res.append((str(name).strip(), None))
            elif str(t).strip():
                res.append((str(t).strip(), None))
        return res
    if isinstance(val, str):
        # Strip Python list repr if it was accidentally serialised that way
        stripped = val.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            inner = stripped[1:-1]
            tags = [t.strip().strip("'\"") for t in inner.split(',') if t.strip().strip("'\"")]
            return [(t, None) for t in tags if t]
        if ':' not in val:
            # Plain delimited tag list, no scores (supports comma and semicolon)
            parts = val.replace(';', ',').split(',')
            return [(t.strip(), None) for t in parts if t.strip()]
        pairs = []
        for p in val.replace(';', ',').split(','):
            p = p.strip()
            if not p:
                continue
            if ':' in p:
                parts = p.split(':', 1)
                try:
                    score = float(parts[1])
                except ValueError:
                    score = None
                pairs.append((parts[0].strip(), score))
            else:
                pairs.append((p, None))
        return pairs
    return []


def format_all_moods(mood_val, other_features=None, min_score: float = None, fallback_score: float = None):
    """Returns semicolon-separated mood/feature tags filtered by score thresholds.

    Tags are sourced from *mood_val* (mood_vector column) and optionally from
    *other_features* (other_features column), then sorted by score descending.

    Selection rules:
    - Up to 3 tags whose score >= *min_score* (default: MOOD_MIN_SCORE) are kept.
    - If no tags meet *min_score*, the single best tag is used as a fallback
      only if its score >= *fallback_score* (default: MOOD_FALLBACK_SCORE).
    - If ALL tags lack a score (plain tag lists with no scoring info), the first
      3 tags are returned directly without threshold filtering.
    - If nothing qualifies, returns None.
    """
    
    logger.info(mood_val)
    logger.info(other_features)

    if min_score is None:
        min_score = MOOD_MIN_SCORE
    if fallback_score is None:
        fallback_score = MOOD_FALLBACK_SCORE

    pairs = _parse_tag_scores(mood_val) + _parse_tag_scores(other_features)

    if not pairs:
        return None

    # If no tag has a real score, return the first 3 tags without filtering
    if all(score is None for _, score in pairs):
        return '; '.join(tag for tag, _ in pairs[:3])

    # Sort scored tags first (descending), unscored last
    pairs.sort(key=lambda x: x[1] if x[1] is not None else -1, reverse=True)

    # Primary: up to 3 tags at or above the main threshold
    filtered = [(tag, score) for tag, score in pairs if score is not None and score >= min_score][:3]

    if not filtered:
        # Fallback: single best tag if it clears the lower bar
        best_tag, best_score = pairs[0]
        if best_score is not None and best_score >= fallback_score:
            filtered = [(best_tag, best_score)]

    if not filtered:
        return None

    return '; '.join(tag for tag, _ in filtered)



def run_beets_update(file_path: str, bpm: float = None, mood: str = None):
    """Executes the beets CLI using the absolute /media/music path query."""
    if not file_path:
        return False, "Missing file path"
    
    if bpm is None and not mood:
        logger.warning(f"Skipping Beets update for '{file_path}': No BPM or mood values provided.")
        return False, "No BPM or mood specified"

    query = f"path:{file_path}"
    cmd = ["beet", "modify", "-y", "-w", query]
    
    if bpm is not None:
        cmd.append(f"bpm={int(round(float(bpm)))}")
    if mood:
        cmd.append(f"mood={mood}")
        cmd.append(f"genres={mood}")
    
    logger.info(f"{cmd}")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        logger.info(f"Beets output: {result.stdout.strip()}")
    except subprocess.CalledProcessError as e:
        err_msg = e.stderr.strip() or e.stdout.strip()
        logger.error(f"Beets CLI failed for path '{file_path}': {err_msg}")
        return False, err_msg
    except Exception as e:
        logger.exception(f"Unexpected error executing beets CLI for path '{file_path}': {e}")
        return False, str(e)

    
    return True, None


def log_sync_result(audio_path, bpm, mood, success, error):
    """Records the sync outcome in the PostgreSQL audit log table."""
    try:
        db = get_db()
        cur = db.cursor()
        sync_log = table('beets_sync_log')
        bpm_val = int(round(float(bpm))) if bpm is not None else None
        cur.execute(
            "INSERT INTO " + sync_log + " (audio_path, bpm, mood, synced_at, status, error) "
            "VALUES (%s, %s, %s, to_char(now(), 'DD-MM-YYYY HH24:MI:SS'), %s, %s)",
            (audio_path, bpm_val, mood, 'SUCCESS' if success else 'FAILED', error)
        )
        db.commit()
        cur.close()
    except Exception as e:
        logger.exception(f"Failed to record sync audit log for '{audio_path}': {e}")

def all_analyzed_tracks():
    db = get_db()
    tracks = []
    try:
        cur = db.cursor()
        query = """
            SELECT tsm.file_path, s.tempo, s.mood_vector, s.title, s.author, s.other_features
            FROM score s
            JOIN track_server_map tsm ON s.item_id = tsm.item_id
            WHERE tsm.file_path IS NOT NULL 
        """
        cur.execute(query)
                    
        for r in cur.fetchall():
            file_path, tempo, mood_vector, title, author, other_features = r[0], r[1], r[2], r[3], r[4], r[5]
            tracks.append({
                'path': file_path,
                'bpm': tempo,
                'mood': mood_vector,
                'other_features': other_features,
                'title': title,
                'author': author
            })
        cur.close()
    except Exception as e:
        db.rollback()
        logger.exception("Failed to query analyzed tracks from score and track_server_map")
        raise
    return tracks

def search_analyzed_tracks(search_query=None):
    """Queries analyzed tracks by joining score with track_server_map using tsm.file_path."""
    db = get_db()
    tracks = []
    try:
        cur = db.cursor()
        if search_query:
            query = """
                SELECT tsm.file_path, s.tempo, s.mood_vector, s.title, s.author, s.other_features
                FROM score s
                JOIN track_server_map tsm ON s.item_id = tsm.item_id
                WHERE tsm.file_path IS NOT NULL AND (tsm.file_path ILIKE %s OR s.title ILIKE %s OR s.author ILIKE %s)
                LIMIT 50
            """
            term = f"%{search_query}%"
            cur.execute(query, (term, term, term))
        else:
            query = """
                SELECT tsm.file_path, s.tempo, s.mood_vector, s.title, s.author, s.other_features
                FROM score s
                JOIN track_server_map tsm ON s.item_id = tsm.item_id
                WHERE tsm.file_path IS NOT NULL 
                LIMIT 25
            """
            cur.execute(query)
        
        for r in cur.fetchall():
            file_path, tempo, mood_vector, title, author, other_features = r[0], r[1], r[2], r[3], r[4], r[5]
            tracks.append({
                'path': file_path,
                'bpm': tempo,
                'mood': mood_vector,
                'other_features': other_features,
                'title': title,
                'author': author
            })
        cur.close()
    except Exception as e:
        db.rollback()
        logger.exception("Failed to query analyzed tracks from score and track_server_map")
        raise
    return tracks

def on_analyzed(song):
    """Hook triggered automatically after a song is analyzed."""

    print(song)

    item_id = song.get('item_id')
    analysis = song.get('analysis') or {}
    metadata = song.get('metadata') or {}
    media_item = song.get('media_item') or {}

    # Extract analysis data (freshly computed by audiomuse)
    bpm = analysis.get('tempo') or analysis.get('bpm')
    mood = analysis.get('moods') or analysis.get('mood')
    other_features = analysis.get('other_features')

    # Resolve target music file path
    audio_path = (
        metadata.get('file_path') or 
        metadata.get('FilePath') or 
        media_item.get('path') or 
        media_item.get('FilePath') or 
        media_item.get('Path') or 
        metadata.get('path')
    )

    # If any fields are missing, try querying the local database
    db_audio_path, db_bpm, db_mood, db_other = None, None, None, None
    if item_id and not (audio_path and bpm and mood and other_features):
        try:
            db = get_db()
            cur = db.cursor()
            cur.execute("""
                SELECT tsm.file_path, s.tempo, s.mood_vector, s.other_features
                FROM score s
                JOIN track_server_map tsm ON s.item_id = tsm.item_id
                WHERE s.item_id = %s
            """, (item_id,))
            row = cur.fetchone()
            if row:
                db_audio_path, db_bpm, db_mood, db_other = row
            cur.close()
        except Exception as e:
            logger.warning(f"Failed to lookup track info for item_id {item_id}: {e}")

    audio_path = audio_path or db_audio_path
    if not audio_path and song.get('audio_path'):
        raw_path = song.get('audio_path')
        if not raw_path.startswith('/var/lib/audiomuse-ai/temp_audio') and '/temp_' not in raw_path:
            audio_path = raw_path

    bpm = bpm if bpm is not None else (db_bpm if db_bpm is not None else media_item.get('bpm'))
    mood = mood if mood is not None else (db_mood if db_mood is not None else media_item.get('moods'))
    other_features = other_features if other_features is not None else (db_other if db_other is not None else media_item.get('other_features'))

    try:
        if bpm is not None and float(bpm) == 0.0:
            bpm = None
    except (ValueError, TypeError):
        bpm = None

    if not audio_path:
        logger.error(f"Received analyzed song hook with missing audio path for item_id {item_id}")
        return

    merged_mood = format_all_moods(mood, other_features=other_features)
    success, error = run_beets_update(audio_path, bpm=bpm, mood=merged_mood)
    log_sync_result(audio_path, bpm, merged_mood, success, error)
    
@bp.route('/sync-single', methods=['POST'])
def sync_single():
    """Manually syncs a single selected song path."""
    audio_path = request.form.get('audio_path')
    if not audio_path:
        logger.error("sync-single invoked with empty audio_path")
        return redirect(url_for('beets_export.home'))

    db = get_db()
    cur = db.cursor()
    bpm, mood, other_features = None, None, None
    try:
        cur.execute("""
            SELECT s.tempo, s.mood_vector, s.other_features
            FROM score s
            JOIN track_server_map tsm ON s.item_id = tsm.item_id
            WHERE tsm.file_path = %s LIMIT 1
        """, (audio_path,))
        row = cur.fetchone()
        if row:
            bpm, mood, other_features = row
        else:
            cur.execute("SELECT bpm, mood FROM " + table('beets_sync_log') + " WHERE audio_path = %s ORDER BY id DESC LIMIT 1", (audio_path,))
            log_row = cur.fetchone()
            if log_row:
                bpm, mood = log_row
    except Exception as e:
        logger.exception(f"Failed to lookup metadata for path '{audio_path}': {e}")
    finally:
        cur.close()
        
    merged_mood = format_all_moods(mood, other_features=other_features)
    success, error = run_beets_update(audio_path, bpm=bpm, mood=merged_mood)
    log_sync_result(audio_path, bpm, merged_mood, success, error)
        
    return redirect(url_for('beets_export.home'))

@bp.route('/sync-all', methods=['POST'])
def sync_all():
    """Iterates through all tracked audio paths in the library and syncs them to Beets."""
    try:
        tracks = all_analyzed_tracks()
    except Exception as e:
        logger.exception(f"Batch sync failed during track retrieval: {e}")
        return redirect(url_for('beets_export.home'))

    for track in tracks:
        merged_mood = format_all_moods(track['mood'], other_features=track.get('other_features'))
        success, error = run_beets_update(
            track['path'], 
            bpm=track['bpm'], 
            mood=merged_mood
        )
        log_sync_result(track['path'], track['bpm'], merged_mood, success, error)

    return redirect(url_for('beets_export.home'))

@bp.route('/')
def home():
    """Renders the dashboard with dynamic search table and history."""
    search_query = request.args.get('q', '').strip()
    
    try:
        tracks = search_analyzed_tracks(search_query)
    except Exception as e:
        tracks = []
        logger.error(f"Error loading analyzed tracks for UI: {e}")
    
    db = get_db()
    try:
        cur = db.cursor()
        cur.execute(
            "SELECT audio_path, bpm, mood, synced_at, status, error FROM " + table('beets_sync_log') +
            " ORDER BY id DESC LIMIT 25"
        )
        rows = cur.fetchall()
        cur.close()
    except Exception as e:
        db.rollback()
        logger.exception("Failed to load sync audit log history for UI")
        rows = []

    search_header = (
        '<tr>'
        '<th style="padding:.3rem .6rem;text-align:left;">Track</th>'
        '<th style="padding:.3rem .6rem;text-align:left;">Path</th>'
        '<th style="padding:.3rem .6rem;text-align:right;">BPM</th>'
        '<th style="padding:.3rem .6rem;text-align:left;">Moods</th>'
        '<th style="padding:.3rem .6rem;text-align:center;">Action</th>'
        '</tr>'
    )
    
    search_detail = ''.join(
        '<tr>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;"><strong>{html.escape(t["author"] or "Unknown")}</strong> - {html.escape(t["title"] or "Untitled")}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;word-break:break-all;font-size:0.85rem;">{html.escape(t["path"])}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;text-align:right;">{round(t["bpm"], 1) if t["bpm"] else "-"}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;">{html.escape(format_all_moods(t["mood"], other_features=t.get("other_features")) or "-")}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;text-align:center;">'
        f'<form method="POST" action="{url_for("beets_export.sync_single")}" style="margin:0;">'
        f'<input type="hidden" name="audio_path" value="{html.escape(t["path"])}">'
        f'<button type="submit" class="btn btn-sm btn-primary" style="font-size:0.8rem;padding:0.1rem 0.5rem;">Sync</button>'
        f'</form></td>'
        '</tr>'
        for t in tracks
    )
    
    search_table_html = (
        '<table style="border-collapse:collapse;font-size:.9rem;width:100%;margin-top:0.5rem;">'
        f'{search_header}{search_detail}</table>'
    ) if tracks else '<p class="text-muted">No tracks found matching your query.</p>'

    history_header = (
        '<tr>'
        '<th style="padding:.3rem .6rem;text-align:left;">Path</th>'
        '<th style="padding:.3rem .6rem;text-align:right;">BPM</th>'
        '<th style="padding:.3rem .6rem;text-align:left;">Moods</th>'
        '<th style="padding:.3rem .6rem;text-align:left;">Synced At</th>'
        '<th style="padding:.3rem .6rem;text-align:center;">Status</th>'
        '</tr>'
    )
    
    history_detail = ''.join(
        '<tr>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;word-break:break-all;">{html.escape(path)}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;text-align:right;">{bpm or "-"}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;">{html.escape(mood or "-")}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;">{html.escape(synced_at)}</td>'
        f'<td style="padding:.3rem .6rem;border-top:1px solid #ccc;text-align:center;color:{"green" if status == "SUCCESS" else "red"};"><strong>{status}</strong></td>'
        '</tr>'
        for path, bpm, mood, synced_at, status, error in rows
    )
    
    history_table_html = (
        '<table style="border-collapse:collapse;font-size:.9rem;width:100%;">'
        f'{history_header}{history_detail}</table>'
    ) if rows else '<p>No sync events recorded yet.</p>'

    body = (
        '<h2>Beets Metadata Export</h2>'
        '<p class="text-muted">Automatically exports analyzed BPM and semicolon-separated mood tags to your local Beets library and audio file tags.</p>'
        
        # Search UI Block
        '<div style="margin: 1.5rem 0; padding: 1rem; background: rgba(0,0,0,0.03); border-radius: 6px;">'
        '<h4>Search & Sync Library Songs</h4>'
        f'<form method="GET" action="{url_for("beets_export.home")}" style="margin-bottom: 1rem; display: flex; gap: 0.5rem;">'
        f'<input type="text" name="q" value="{html.escape(search_query)}" placeholder="Search by title, artist, or path..." class="form-control" style="max-width: 400px;">'
        '<button type="submit" class="btn btn-secondary">Search</button>'
        '</form>'
        f'<div style="max-height: 350px; overflow-y: auto;">{search_table_html}</div>'
        '</div>'

        # Batch Sync All
        '<div style="margin: 1.5rem 0;">'
        f'<form method="POST" action="{url_for("beets_export.sync_all")}">'
        '<button type="submit" class="btn btn-outline-primary">Sync All Analyzed Songs</button>'
        '</form>'
        '</div>'
        
        # History Section
        '<div style="margin-top:2rem; max-height: 350px; overflow-y: auto;">'
        '<h4>Recent Sync History</h4>'
        f'{history_table_html}'
        '</div>'
    )
    return render_page(body, title='Beets Export')

def register(ctx):
    ctx.on_install(migrate)
    ctx.add_blueprint(bp)
    ctx.add_menu_item('Beets Export', 'beets_export.home')
    ctx.on_song_analyzed(on_analyzed)
