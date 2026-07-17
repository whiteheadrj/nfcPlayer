// Command nfcplayer is a Go port of nfc_player.py: an NFC audio player for the
// Raspberry Pi.
//
// Tap an NFC tag on an ACR122U reader; the tag's UID is looked up in a Google
// Sheet (columns: Tag, Book Title, Link) and the audio URL from that row is
// streamed with mpv through the Pi's 3.5mm jack.
//
// Modes:
//
//	nfcplayer             run the player
//	nfcplayer --register  just print tag UIDs (for filling in the sheet)
package main

import (
	"encoding/csv"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	pcsc "github.com/gballet/go-libpcsclite"
)

// How often the reader is polled for a newly-presented tag. The pure-Go PC/SC
// client has no blocking "card inserted" event, so we poll instead.
const pollInterval = 250 * time.Millisecond

// ---------------------------------------------------------------------------
// Configuration (override via environment variables, e.g. in the systemd unit)
// ---------------------------------------------------------------------------
var (
	sheetID             = env("SHEET_ID", "1EW7mGv9IMcwiIqwEJGDhc8e-PXXOceAWLizcIYIbi-U")
	sheetRefreshSeconds = envInt("SHEET_REFRESH_SECONDS", 300)
	// Extra args for mpv, e.g. AUDIO_DEVICE="alsa/hw:0,0" to force an output.
	audioDevice = env("AUDIO_DEVICE", "")
	// Tapping the tag that is currently playing stops it (1) or restarts it (0).
	sameTagStops = env("SAME_TAG_STOPS", "1") == "1"
	playerCmd    = env("PLAYER_CMD", "mpv --no-video --really-quiet")
)

func csvURL() string {
	return fmt.Sprintf("https://docs.google.com/spreadsheets/d/%s/export?format=csv", sheetID)
}

var getUIDAPDU = []byte{0xFF, 0xCA, 0x00, 0x00, 0x00}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, ok := os.LookupEnv(key); ok {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

var nonHex = regexp.MustCompile(`[^0-9A-F]`)

// normalizeUID returns the canonical form of a tag UID: uppercase hex, no
// separators.
func normalizeUID(uid string) string {
	return nonHex.ReplaceAllString(strings.ToUpper(uid), "")
}

var (
	driveFileRe = regexp.MustCompile(`drive\.google\.com/file/d/([\w-]+)`)
	driveOpenRe = regexp.MustCompile(`drive\.google\.com/open\?id=([\w-]+)`)
)

// directAudioURL rewrites common share links to something a media player can
// stream.
func directAudioURL(url string) string {
	url = strings.TrimSpace(url)
	m := driveFileRe.FindStringSubmatch(url)
	if m == nil {
		m = driveOpenRe.FindStringSubmatch(url)
	}
	if m != nil {
		return "https://drive.google.com/uc?export=download&id=" + m[1]
	}
	if strings.Contains(url, "dropbox.com") {
		url = strings.ReplaceAll(url, "?dl=0", "?dl=1")
		url = strings.ReplaceAll(url, "&dl=0", "&dl=1")
		if !strings.Contains(url, "dl=1") && !strings.Contains(url, "dl.dropboxusercontent") {
			if strings.Contains(url, "?") {
				url += "&dl=1"
			} else {
				url += "?dl=1"
			}
		}
	}
	return url
}

// entry is the (title, url) pair a UID maps to.
type entry struct {
	title string
	url   string
}

// TagTable is a UID -> entry mapping loaded from the Google Sheet.
type TagTable struct {
	mu         sync.Mutex
	table      map[string]entry
	loadedOnce bool
}

func NewTagTable() *TagTable {
	return &TagTable{table: map[string]entry{}}
}

func (t *TagTable) refresh() bool {
	client := http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(csvURL())
	if err != nil {
		log.Printf("WARNING Could not fetch sheet: %v", err)
		return false
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("WARNING Could not read sheet: %v", err)
		return false
	}

	reader := csv.NewReader(strings.NewReader(string(body)))
	reader.FieldsPerRecord = -1
	rows, err := reader.ReadAll()
	if err != nil {
		log.Printf("WARNING Could not parse sheet: %v", err)
		return false
	}
	if len(rows) == 0 {
		log.Printf("WARNING Sheet is empty")
		return false
	}

	header := make([]string, len(rows[0]))
	for i, h := range rows[0] {
		header[i] = strings.ToLower(strings.TrimSpace(h))
	}
	col := func(def int, names ...string) int {
		for _, name := range names {
			for i, h := range header {
				if h == name {
					return i
				}
			}
		}
		return def
	}
	tagCol := col(0, "tag", "uid", "id")
	titleCol := col(1, "book title", "title", "book", "name")
	linkCol := col(2, "link", "url", "audio", "audio url")

	maxCol := tagCol
	if linkCol > maxCol {
		maxCol = linkCol
	}

	table := map[string]entry{}
	for _, row := range rows[1:] {
		if len(row) <= maxCol {
			continue
		}
		uid := normalizeUID(row[tagCol])
		url := strings.TrimSpace(row[linkCol])
		if uid == "" || url == "" {
			continue
		}
		title := ""
		if len(row) > titleCol {
			title = strings.TrimSpace(row[titleCol])
		}
		if title == "" {
			title = uid
		}
		table[uid] = entry{title: title, url: directAudioURL(url)}
	}

	t.mu.Lock()
	t.table = table
	t.loadedOnce = true
	t.mu.Unlock()
	log.Printf("INFO Sheet loaded: %d tag(s)", len(table))
	return true
}

func (t *TagTable) lookup(uid string) (entry, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e, ok := t.table[uid]
	return e, ok
}

func (t *TagTable) loaded() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.loadedOnce
}

// Player wraps a single mpv subprocess streaming the current audio URL.
type Player struct {
	cmd        *exec.Cmd
	currentUID string
	done       chan struct{} // closed when cmd exits
}

func (p *Player) baseCmd() []string {
	cmd := strings.Fields(playerCmd)
	if audioDevice != "" {
		cmd = append(cmd, "--audio-device="+audioDevice)
	}
	return cmd
}

func (p *Player) isPlaying(uid string) bool {
	if p.cmd == nil {
		return false
	}
	select {
	case <-p.done: // process has exited
		return false
	default:
	}
	return uid == "" || uid == p.currentUID
}

func (p *Player) play(uid, title, url string) {
	p.stop()
	log.Printf("INFO Playing '%s' (%s)", title, url)
	args := append(p.baseCmd(), url)
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Printf("ERROR Could not start player — is mpv installed? %v", err)
		return
	}
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		close(done)
	}()
	p.cmd = cmd
	p.currentUID = uid
	p.done = done
}

func (p *Player) stop() {
	if p.cmd != nil && p.isPlaying("") {
		log.Printf("INFO Stopping playback")
		p.cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-p.done:
		case <-time.After(3 * time.Second):
			p.cmd.Process.Kill()
			<-p.done
		}
	}
	p.cmd = nil
	p.currentUID = ""
	p.done = nil
}

// readUID connects to a reader that has a card present and reads its UID.
func readUID(client *pcsc.Client, reader string) (string, error) {
	card, err := client.Connect(reader, pcsc.ShareShared, pcsc.ProtocolAny)
	if err != nil {
		return "", err
	}
	defer card.Disconnect(pcsc.LeaveCard)

	rsp, _, err := card.Transmit(getUIDAPDU)
	if err != nil {
		return "", err
	}
	if len(rsp) < 2 {
		return "", fmt.Errorf("short response (%d bytes)", len(rsp))
	}
	data := rsp[:len(rsp)-2]
	sw1, sw2 := rsp[len(rsp)-2], rsp[len(rsp)-1]
	if sw1 != 0x90 {
		return "", fmt.Errorf("reader returned status %02X %02X", sw1, sw2)
	}
	return normalizeUID(hexString(data)), nil
}

func hexString(b []byte) string {
	parts := make([]string, len(b))
	for i, x := range b {
		parts[i] = fmt.Sprintf("%02X", x)
	}
	return strings.Join(parts, " ")
}

// monitorTags polls every reader for card insertions and sends each newly
// presented tag's UID on the returned channel. A UID is emitted once per
// insertion: while a tag stays on the reader it stays "present" and is not
// re-emitted; lifting it and tapping again re-emits.
func monitorTags(client *pcsc.Client) <-chan string {
	uids := make(chan string, 16)
	go func() {
		present := map[string]bool{} // reader name -> a tag was successfully read
		for {
			time.Sleep(pollInterval)

			readers, err := client.ListReaders()
			if err != nil || len(readers) == 0 {
				present = map[string]bool{}
				continue
			}

			for _, reader := range readers {
				uid, err := readUID(client, reader)
				if err != nil {
					// No card, or it was lifted — reset so the next tap fires.
					present[reader] = false
					continue
				}
				if !present[reader] {
					present[reader] = true
					uids <- uid
				}
			}
		}
	}()
	return uids
}

func runRegisterMode(client *pcsc.Client) {
	fmt.Println("Register mode: tap tags to print their UIDs (Ctrl-C to quit).")
	fmt.Println("Paste each UID into the 'Tag' column of the Google Sheet.")
	fmt.Println()
	uids := monitorTags(client)
	for uid := range uids {
		fmt.Printf("Tag UID: %s\n", uid)
	}
}

func runPlayer(client *pcsc.Client) {
	tags := NewTagTable()
	tags.refresh()

	player := &Player{}
	uids := monitorTags(client)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		log.Printf("INFO Shutting down")
		player.stop()
		os.Exit(0)
	}()

	log.Printf("INFO Ready — tap a tag")
	lastRefresh := time.Now()
	var lastUID string
	var lastTime time.Time

	for {
		var uid string
		select {
		case uid = <-uids:
		case <-time.After(5 * time.Second):
			if time.Since(lastRefresh) > time.Duration(sheetRefreshSeconds)*time.Second {
				tags.refresh()
				lastRefresh = time.Now()
			}
			continue
		}

		// Debounce chattering reads of the same physical tap.
		now := time.Now()
		if uid == lastUID && now.Sub(lastTime) < 2*time.Second {
			continue
		}
		lastUID, lastTime = uid, now

		e, ok := tags.lookup(uid)
		if !ok {
			// Maybe the row was just added — refresh and retry once.
			tags.refresh()
			lastRefresh = time.Now()
			e, ok = tags.lookup(uid)
		}
		if !ok {
			log.Printf("WARNING Unknown tag %s — add it to the sheet's Tag column", uid)
			continue
		}

		if sameTagStops && player.isPlaying(uid) {
			player.stop()
		} else {
			player.play(uid, e.title, e.url)
		}
	}
}

func main() {
	register := flag.Bool("register", false, "just print tag UIDs (for filling in the sheet)")
	flag.Parse()

	log.SetFlags(log.Ltime)

	client, err := pcsc.EstablishContext(pcsc.PCSCDSockName, pcsc.ScopeSystem)
	if err != nil {
		log.Fatalf("Could not connect to the PC/SC daemon (is pcscd running?): %v", err)
	}
	defer client.ReleaseContext()

	if *register {
		runRegisterMode(client)
	} else {
		runPlayer(client)
	}
}
