#+build windows
package calc

import "base:runtime"

import "core:mem"
import "core:strconv"
import "core:sys/windows"

// TODO(ema):
// - Keyboard events
// - Config file to store window position
// - Bigger font size
// - Better display text alignment
// - Rational numbers
// - +/- button
// - Set decimal button text to . or , based on locale
// - -no-crt
// - Better error messages on failure to create window or register class


CLIENT_WIDTH  :: 250;
CLIENT_HEIGHT :: 350;

module_instance: windows.HINSTANCE;


Calc_State :: struct {
	n1: i64,
	n2: i64,
	op: Operator,
}

Display_State :: struct {
	text: [MAX_DIGIT_LENGTH + 1]u8,
	write_cursor: int,
	append_to_text: bool,
}

Operator :: enum {
	None = 0, Plus, Minus, Times, Divide,
}

MAX_DIGIT_LENGTH :: 31;

DIVISION_BY_ZERO_TEXT :: "Error";

calc_state: Calc_State;
display_state: Display_State;


main :: proc() {
	module_instance = windows.HINSTANCE(windows.GetModuleHandleW(nil));
	
	window_class: windows.WNDCLASSEXA = ---;
	window_class.cbSize        = size_of(window_class);
	window_class.style         = windows.CS_DBLCLKS;
	window_class.lpfnWndProc   = window_callback;
	window_class.cbClsExtra    = 0;
	window_class.cbWndExtra    = 0;
	window_class.hInstance     = module_instance;
	window_class.hIcon         = nil; // TODO(ema): Icon
	window_class.hCursor       = nil; // TODO(ema): Cursor
	window_class.hbrBackground = windows.HBRUSH(uintptr(windows.COLOR_WINDOW + 1));
	window_class.lpszMenuName  = nil;
	window_class.lpszClassName = "main";
	window_class.hIconSm       = nil; // TODO(ema): Small icon
	
	if atom := RegisterClassExA(&window_class); atom != 0 {
		STYLE :: windows.WS_OVERLAPPEDWINDOW~windows.WS_THICKFRAME~windows.WS_MAXIMIZEBOX;
		
		desktop_rect: windows.RECT = ---;
		windows.GetClientRect(windows.GetDesktopWindow(), &desktop_rect);
		
		client_left   := (desktop_rect.right  / 2) - (CLIENT_WIDTH  / 2);
		client_top    := (desktop_rect.bottom / 2) - (CLIENT_HEIGHT / 2);
		
		client_right  := client_left + CLIENT_WIDTH;
		client_bottom := client_top + CLIENT_HEIGHT;
		
		window_rect   := windows.RECT{ client_left, client_top, client_right, client_bottom };
		adjusted      := windows.AdjustWindowRectEx(&window_rect, STYLE, false, 0);
		
		if window := CreateWindowExA(0, window_class.lpszClassName, "Calc", STYLE, window_rect.left, window_rect.top, window_rect.right - window_rect.left, window_rect.bottom - window_rect.top, nil, nil, module_instance, nil); window != nil {
			
			_ = windows.ShowWindow(window, windows.SW_SHOW);
			
			should_quit := false;
			for !should_quit {
				message: windows.MSG = ---;
				message_result := windows.GetMessageW(&message, nil, 0, 0);
				for ; i32(message_result) != -1; message_result = GetMessageA(&message, nil, 0, 0) {
					if message.message == windows.WM_QUIT {
						should_quit = true;
						break;
					}
					
					windows.TranslateMessage(&message);
					DispatchMessageA(&message);
				}
				
				allow_break();
			}
		} else {
			code := windows.GetLastError();
			MessageBoxA(nil, "Sorryyy...", nil, windows.MB_OK|windows.MB_ICONERROR);
		}
	} else {
		code := windows.GetLastError();
		MessageBoxA(nil, "Sorryyy...", nil, windows.MB_OK|windows.MB_ICONERROR);
	}
	
	windows.ExitProcess(0);
}

window_callback :: proc "system" (window: windows.HWND, message_kind: u32, wparam: windows.WPARAM, lparam: windows.LPARAM) -> windows.LRESULT {
	context = runtime.default_context();
	
	result: windows.LRESULT;
    switch message_kind {
		case windows.WM_CREATE: {
			result = create_controls(window);
			
			display_state.text[0] = '0';
			display_state.write_cursor = 1;
		}
		
		case windows.WM_CLOSE, windows.WM_DESTROY: {
			windows.PostQuitMessage(0);
        }
		
		case windows.WM_COMMAND: {
			menu := Control_Menu(wparam);
			#partial switch menu {
				case .N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9, .N0: {
					
					n := u8(0);
					#partial switch menu {
						case .N1: n = '1';
						case .N2: n = '2';
						case .N3: n = '3';
						case .N4: n = '4';
						case .N5: n = '5';
						case .N6: n = '6';
						case .N7: n = '7';
						case .N8: n = '8';
						case .N9: n = '9';
						case .N0: n = '0';
					}
					
					if display_state.append_to_text {
						if display_state.write_cursor < MAX_DIGIT_LENGTH {
							display_state.text[display_state.write_cursor] = n;
							display_state.write_cursor += 1;
						}
					} else {
						display_state.text[0] = n;
						display_state.write_cursor  = 1;
					}
					
					display_state.append_to_text = true;
				}
				
				case .Add, .Sub, .Mul, .Div: {
					//
					// - The display ends in a number:
					//   => Parse the number, store it
					//      Append this operator to the input text
					// - The display ends in an operator:
					//   => The display is storing input, and it is already parsed
					//      Simply replace the operator (both in calc state and in the display)
					//
					
					o := Operator.None;
					c := u8('?');
					#partial switch menu {
						case .Add: c = '+'; o = .Plus;
						case .Sub: c = '-'; o = .Minus;
						case .Mul: c = '*'; o = .Times;
						case .Div: c = '/'; o = .Divide;
					}
					
					assert(display_state.write_cursor > 0);
					if is_digit(display_state.text[display_state.write_cursor - 1]) {
						s := display_state.text[:display_state.write_cursor];
						n, ok := strconv.parse_i64_of_base(transmute(string) s, base = 10);
						assert(ok, "Invalid parsed number, internal error.");
						
						divided_by_zero := false;
						
						if display_state.append_to_text {
							if calc_state.op == .None {
								calc_state.n1 = n;
							} else {
								partial_result := i64(0);
								
								switch calc_state.op {
									case .Plus:   partial_result = calc_state.n1 + calc_state.n2;
									case .Minus:  partial_result = calc_state.n1 - calc_state.n2;
									case .Times:  partial_result = calc_state.n1 * calc_state.n2;
									case .Divide: {
										if calc_state.n2 != 0 {
											partial_result = calc_state.n1 / calc_state.n2;
										} else {
											calc_state = {};
											display_state = {};
											
											text := DIVISION_BY_ZERO_TEXT;
											copy(display_state.text[:], text);
											display_state.write_cursor = len(text);
											
											divided_by_zero = true;
										}
									}
									
									case .None:   panic("Unreachable");
									case:         panic("Invalid switch case.");
								}
								
								if !divided_by_zero {
									calc_state.n1 = partial_result;
									calc_state.n2 = n;
								}
							}
						}
						
						if !divided_by_zero {
							display_state.text[display_state.write_cursor] = c;
							display_state.write_cursor += 1;
						}
					} else {
						display_state.text[display_state.write_cursor - 1] = c;
					}
					
					calc_state.op = o;
					
					display_state.append_to_text = false;
				}
				
				case .Percent: {
					s := display_state.text[:display_state.write_cursor];
					n, ok := strconv.parse_i64_of_base(transmute(string) s, base = 10);
					assert(ok, "Invalid parsed number, internal error.");
					
					percent := calc_state.n2 * calc_state.n1 / 100;
					
					divided_by_zero := false;
					
					result := i64(0);
					switch calc_state.op {
						case .Plus:   result = calc_state.n1 + percent;
						case .Minus:  result = calc_state.n1 - percent;
						case .Times:  result = calc_state.n1 * percent;
						case .Divide: {
							if percent != 0 {
								result = calc_state.n1 / percent;
							} else {
								calc_state = {};
								display_state = {};
								
								text := DIVISION_BY_ZERO_TEXT;
								copy(display_state.text[:], text);
								display_state.write_cursor = len(text);
								
								divided_by_zero = true;
							}
						}
						
						case .None:   result = 0;
						case:         panic("Invalid switch case.");
					}
					
					if !divided_by_zero {
						calc_state.n1 = result;
						calc_state.n2 = percent;
						
						// Write to display
						display_string := strconv.append_int(display_state.text[:], result, base = 10);
						display_state.write_cursor = len(display_string);
					}
				}
				
				case .Equals: {
					//
					// - We only have a number, no operation:
					//   => Mark the display as currently storing an output
					// - We have a number and an operation:
					//   => Do the operation, display the result, save the number for repeated = presses
					//      Store the result in place of the 1st number
					//      Mark the display as currently storing an output
					// - We have two numbers and an operation:
					//   => Do the operation between those two numbers
					//      Store the result in place of the 1st number
					//      Mark the display as currently storing an output
					//
					
					//
					// The latter 2 cases can be collapsed as such:
					// - If the display is storing an input, parse it and store it in place of 2nd number
					//   If it is storing an output, do nothing
					// - Do the operation between n1 and n2
					// - Write result to n1
					// - Mark display as storing output
					//
					
					s := display_state.text[:display_state.write_cursor];
					n, ok := strconv.parse_i64_of_base(transmute(string) s, base = 10);
					assert(ok, "Invalid parsed number, internal error.");
					
					if display_state.append_to_text {
						calc_state.n2 = n;
					}
					
					divided_by_zero := false;
					
					result := i64(0);
					switch calc_state.op {
						case .Plus:   result = calc_state.n1 + calc_state.n2;
						case .Minus:  result = calc_state.n1 - calc_state.n2;
						case .Times:  result = calc_state.n1 * calc_state.n2;
						case .Divide: {
							if calc_state.n2 != 0 {
								result = calc_state.n1 / calc_state.n2;
							} else {
								calc_state = {};
								display_state = {};
								
								text := DIVISION_BY_ZERO_TEXT;
								copy(display_state.text[:], text);
								display_state.write_cursor = len(text);
								
								divided_by_zero = true;
							}
						}
						
						case .None:   result = n;
						case:         panic("Invalid switch case.");
					}
					
					if !divided_by_zero {
						calc_state.n1 = result;
						
						// Write to display
						display_string := strconv.append_int(display_state.text[:], result, base = 10);
						display_state.write_cursor = len(display_string);
						
						display_state.append_to_text = false;
					}
				}
				
				case .AC: {
					calc_state = {};
					display_state = {};
					
					display_state.text[0] = '0';
					display_state.write_cursor = 1;
				}
			}
			
			// Update display
			null_terminated: [MAX_DIGIT_LENGTH + 1]u8;
			copy(null_terminated[:], display_state.text[:display_state.write_cursor]);
			
			display_control := controls[Control_Menu.Label].control;
			ok := SetWindowTextA(display_control, transmute(cstring) raw_data(null_terminated[:]));
			
			allow_break();
		}
		
		case: {
			result = DefWindowProcA(window, message_kind, wparam, lparam);
		}
    }
	
	return result;
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_space :: proc(b: u8) -> bool {
	return b == ' ' || b == '\n' || b == '\r' || b == '\t';
}


//~ Controls

Control_Menu :: enum {
	Label = 0,
	
	AC,
	Plus_Minus,
	Percent,
	Div,
	
	N1,
	N2,
	N3,
	Mul,
	
	N4,
	N5,
	N6,
	Sub,
	
	N7,
	N8,
	N9,
	Add,
	
	N0,
	Decimal,
	Equals,
}

Control :: struct {
	menu: windows.HMENU,
	control: windows.HWND,
}

controls: [len(Control_Menu) + 1]Control;

create_controls :: proc(window: windows.HWND) -> windows.LRESULT {
	
	NUM_BUTTON_COLS  ::  4;
	NUM_BUTTON_ROWS  ::  5;
	
	SPACE_AROUND     :: 10;
	SPACE_BETWEEN    ::  5;
	
	NUM_DISPLAY_ROWS ::  1;
	
	BUTTON_WIDTH    :: (CLIENT_WIDTH  - 2*SPACE_AROUND - (NUM_BUTTON_COLS-1)*SPACE_BETWEEN) / NUM_BUTTON_COLS;
	BUTTON_HEIGHT   :: (CLIENT_HEIGHT - 2*SPACE_AROUND - (NUM_BUTTON_ROWS+NUM_DISPLAY_ROWS-1)*SPACE_BETWEEN) / (NUM_BUTTON_ROWS+NUM_DISPLAY_ROWS);
	
	BUTTON_WIDTH_2  :: BUTTON_WIDTH  *2 + SPACE_BETWEEN;
	BUTTON_WIDTH_4  :: BUTTON_WIDTH_2*2 + SPACE_BETWEEN;
	
	STYLE :: windows.WS_TABSTOP|windows.WS_CHILD|windows.WS_VISIBLE;
	STYLE_BUTTON :: windows.BS_DEFPUSHBUTTON|windows.WS_BORDER;
	
	x: i32 = SPACE_AROUND;
	y: i32 = SPACE_AROUND;
	w: i32 = BUTTON_WIDTH_4;
	h: i32 = BUTTON_HEIGHT;
	m := Control_Menu.Label;
	controls[Control_Menu.Label].control = CreateWindowExA(0, "static", "0", STYLE|windows.SS_RIGHT, x, y, w, h, window, nil, module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	y += BUTTON_HEIGHT + SPACE_BETWEEN;
	w  = BUTTON_WIDTH;
	controls[Control_Menu.AC].control = CreateWindowExA(0, "button", "AC", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.Plus_Minus].control = CreateWindowExA(0, "button", "+/-", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.Percent].control = CreateWindowExA(0, "button", "%", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.Div].control = CreateWindowExA(0, "button", "/", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	
	m  = Control_Menu(int(m) + 1);
	y += BUTTON_HEIGHT + SPACE_BETWEEN;
	x  = SPACE_AROUND;
	controls[Control_Menu.N1].control = CreateWindowExA(0, "button", "1", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.N2].control = CreateWindowExA(0, "button", "2", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.N3].control = CreateWindowExA(0, "button", "3", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.Mul].control = CreateWindowExA(0, "button", "*", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	
	m  = Control_Menu(int(m) + 1);
	y += BUTTON_HEIGHT + SPACE_BETWEEN;
	x  = SPACE_AROUND;
	controls[Control_Menu.N4].control = CreateWindowExA(0, "button", "4", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.N5].control = CreateWindowExA(0, "button", "5", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.N6].control = CreateWindowExA(0, "button", "6", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.Sub].control = CreateWindowExA(0, "button", "-", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	
	m  = Control_Menu(int(m) + 1);
	y += BUTTON_HEIGHT + SPACE_BETWEEN;
	x  = SPACE_AROUND;
	controls[Control_Menu.N7].control = CreateWindowExA(0, "button", "7", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.N8].control = CreateWindowExA(0, "button", "8", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.N9].control = CreateWindowExA(0, "button", "9", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.Add].control = CreateWindowExA(0, "button", "+", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	
	m  = Control_Menu(int(m) + 1);
	y += BUTTON_HEIGHT + SPACE_BETWEEN;
	x  = SPACE_AROUND;
	w  = BUTTON_WIDTH_2;
	controls[Control_Menu.N0].control = CreateWindowExA(0, "button", "0", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH_2 + SPACE_BETWEEN;
	w  = BUTTON_WIDTH;
	controls[Control_Menu.Decimal].control = CreateWindowExA(0, "button", ".", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	m  = Control_Menu(int(m) + 1);
	x += BUTTON_WIDTH + SPACE_BETWEEN;
	controls[Control_Menu.Equals].control = CreateWindowExA(0, "button", "=", STYLE|STYLE_BUTTON, x, y, w, h, window, windows.HMENU(uintptr(m)), module_instance, nil);
	
	result: windows.LRESULT;
	
	for i := 0; i < len(controls); i += 1 {
		if controls[i].control == nil {
			result = 1; // TODO(ema): Actual error code
			break;
		}
	}
	
	return result;
}

allow_break :: proc() {}



//~ Foreign imports

foreign import user32 "system:user32.lib"

@(default_calling_convention="system")
foreign user32 {
	RegisterClassExA :: proc(unnamedParam1: ^windows.WNDCLASSEXA) -> windows.ATOM ---;
	CreateWindowExA :: proc(dwExStyle: u32, lpClassName: cstring, lpWindowName: cstring, dwStyle: u32, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: windows.HWND, hMenu: windows.HMENU, hInstance: windows.HINSTANCE, lpParam: rawptr) -> windows.HWND ---;
	SetWindowTextA :: proc(hWnd: windows.HWND, lpString: cstring) -> bool ---;
	DefWindowProcA :: proc(hWnd: windows.HWND, Msg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) -> windows.LRESULT ---;
	DispatchMessageA :: proc(lpMsg: ^windows.MSG) -> windows.LRESULT ---;
	MessageBoxA :: proc(hWnd: windows.HWND, lpText: cstring, lpCaption: cstring, uType: u32) -> i32 ---;
	GetMessageA :: proc(lpMsg: ^windows.MSG, hWnd: windows.HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) -> i32 ---;
}

WNDCLASSEXA :: struct {
	cbSize: u32,
	style: u32,
	lpfnWndProc: windows.WNDPROC,
	cbClsExtra: i32,
	cbWndExtra: i32,
	hInstance: windows.HINSTANCE,
	hIcon: windows.HICON,
	hCursor: windows.HCURSOR,
	hbrBackground: windows.HBRUSH,
	lpszMenuName: cstring,
	lpszClassName: cstring,
	hIconSm: windows.HICON,
}
