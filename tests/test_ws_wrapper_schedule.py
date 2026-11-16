from model.ws_wrapper_schedule import slab_events, no_stall_after_load


def test_literal_seeded_four_row_wavefront():
    a = [list(range(1, 9)), list(range(11, 19))]
    w = [[0, 0] for _ in range(8)]
    w[0][0] = w[4][0] = w[1][1] = w[5][1] = 1
    codes = [[0, 0], [0, 0]]
    events = list(slab_events(a, w, codes, [[100, 200], [300, 400]], True))
    outputs = {}
    for e in events:
        if e["phase"] == 1:
            for c in range(2):
                row = e["slot"] - 3 - c
                if 0 <= row < 2:
                    outputs[row, c] = e["sums"][12 + c]
    assert outputs == {(0, 0): 106, (0, 1): 208, (1, 0): 326, (1, 1): 428}
    assert len(events) == 12
    assert no_stall_after_load(2, 2, True, False) == 45
    assert no_stall_after_load(2, 2, True, True) == 51


def test_bank_permutation_all_rows_groups():
    a = [[1] * 16 for _ in range(16)]
    w = [[1] * 4 for _ in range(16)]
    ev = list(
        slab_events(
            a, w, [[0] * 4 for _ in range(4)], [[0] * 4 for _ in range(16)], False
        )
    )
    seen = {(row, g) for e in ev for _, _, row, g in e["a_reads"]}
    assert seen == {(r, g) for r in range(16) for g in range(4)}
    for e in ev:
        if e["phase"] == 3:
            for c in range(4):
                if 0 <= e["slot"] - 3 - c < 16:
                    assert e["sums"][12 + c] == 16
