package format

import "testing"

func TestPgpass_Valid(t *testing.T) {
	f, ok := Get("pgpass")
	if !ok {
		t.Fatal("pgpass not registered")
	}
	in := "db.example.com:5432:mydb:dbuser:s3cret"
	out, err := f.Format(in, nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != in {
		t.Fatalf("expected verbatim passthrough, got %q", string(out))
	}
}

func TestPgpass_NoArgsAllowed(t *testing.T) {
	f, _ := Get("pgpass")
	_, err := f.Format("h:5432:db:user:pw", []string{"unexpected"})
	if err == nil {
		t.Fatal("expected error when args provided")
	}
}

func TestPgpass_RejectsNewline(t *testing.T) {
	f, _ := Get("pgpass")
	_, err := f.Format("host:5432:db:user:pw\nextra", nil)
	if err == nil {
		t.Fatal("expected error on embedded newline")
	}
}

func TestPgpass_RejectsTrailingNewline(t *testing.T) {
	f, _ := Get("pgpass")
	_, err := f.Format("host:5432:db:user:pw\n", nil)
	if err == nil {
		t.Fatal("expected error on trailing newline (must be exact line)")
	}
}

func TestPgpass_RejectsWrongFieldCount(t *testing.T) {
	f, _ := Get("pgpass")
	cases := []string{
		"only:four:fields:here",
		"too:many:fields:here:plus:one",
		"",
		"nofields",
	}
	for _, in := range cases {
		if _, err := f.Format(in, nil); err == nil {
			t.Errorf("expected error for %q", in)
		}
	}
}

func TestPgpass_AllowsWildcards(t *testing.T) {
	// pgpass allows * in host/port/db/user fields.
	f, _ := Get("pgpass")
	in := "*:*:*:*:s3cret"
	if _, err := f.Format(in, nil); err != nil {
		t.Fatalf("wildcards should be allowed, got %v", err)
	}
}
