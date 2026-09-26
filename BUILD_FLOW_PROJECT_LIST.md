> Cập nhật 26/09/2026: migration 011 đã bổ sung Loại công trình, loại thực hiện và ngân sách. Các giới hạn schema nêu trong báo cáo lịch sử bên dưới được thay thế bởi [báo cáo trường Lead/Project](BUILD_FLOW_LEAD_FIELDS.md).

# Build Flow — bàn giao trang Danh sách dự án, 26/09/2026

## File thay đổi

- `app/app.js`: shell, trang bảng, bộ lọc, phân trang, dữ liệu thật qua JWT/PostgREST; modal tạo từ Lead thành công, menu chi tiết/ẩn/bỏ ẩn, tải XLSX.
- `app/projects.mjs`: lọc/sắp xếp, kỳ so sánh, thống kê, tạo workbook XLSX không dùng công thức.
- `app/style.css`, `app/index.html`: Build Flow, Inter Variable hiện có, navy/blue, sidebar 190/64, header 64, padding 24, khoảng cách 16, bảng cuộn riêng.
- `app/server.mjs`: phục vụ thêm module JS, giữ nguyên CSP và cấu hình chỉ local.
- `package.json`: thêm `app:check`, `app:test`; không thêm dependency.
- `scripts/test-project-list.mjs`, `scripts/test-project-browser.mjs`: kiểm thử logic và UI với database local thật.
- `app/README.md`, tài liệu này, ảnh trong `artifacts/`.

Không sửa SQL, Migration 001–010, RLS hoặc quyết định Lead/Quote/nghiệm thu.

## Hành vi đã triển khai

- Bảng đúng 11 cột; không checkbox hoặc chuyển grid. ID là project_number hiển thị tối thiểu 2 chữ số theo tài liệu nghiệp vụ, UUID vẫn dùng làm khóa.
- Mặc định mới nhất; timestamp đầy đủ và UUID phụ đảm bảo thứ tự ổn định khi trùng thời điểm.
- Tìm tên/ID/UUID/khách hàng đọc được; trạng thái gốc và Quá hạn; lọc ngày tạo 7/30 ngày hoặc tùy chọn, bao gồm hai đầu theo timezone company.
- 20 hoặc 50 dòng/trang; tổng sau lọc; đổi lọc/kích thước/sắp xếp về trang 1.
- Loại dự án ẩn khỏi thống kê. Owner/Admin có mục Đã ẩn và RPC ẩn/bỏ ẩn hiện có.
- Quá hạn là badge riêng, không thay trạng thái. Tính từ Project và 7 loại module/item theo dispatch_overdue, loại trạng thái kết thúc theo SQL, dùng ngày hiện tại của company.
- Tổng/Hoàn thành: kỳ có from/to dùng ngày tạo/ngày hoàn thành; Đang thực hiện/Quá hạn tính hiện tại. So sánh khoảng liền trước cùng số ngày; mặc định so 30 ngày gần nhất khi thời gian là Tất cả. Mẫu số 0 và hiện tại >0 hiển thị — vì tỷ lệ không xác định; cả hai 0 hiển thị 0%.
- XLSX gồm mọi dòng sau lọc, không chỉ trang hiện tại; tải lại với JWT/RLS trước xuất. Các tên có dấu, ký tự XML và chuỗi giống công thức được lưu là inline string.
- Loading, empty, error/thử lại. Logout xóa dữ liệu; login mới reset các bộ lọc.
- Menu sidebar theo ảnh; các màn hình chưa có trong repo được vô hiệu hóa, không tạo liên kết giả. Header có tải lại, danh tính và đăng xuất; chưa triển khai inbox/chuông thông báo.

## Giới hạn backend cần duyệt trước khi hoàn thiện

1. **Loại công trình**: projects chưa có cột hoặc quan hệ tương ứng. Cột UI/XLSX để trống (UI —), không suy từ tên. Đề xuất bổ sung danh mục tenant hoặc trường đã chốt bằng migration mới sau duyệt.
2. **Quyền hiệu lực cho frontend**: roles/role_permissions/permissions yêu cầu role.view; user_permissions yêu cầu user.view. Không thể xác định an toàn quyền của mọi User từ API hiện có. Nút Tạo chỉ hiện khi Owner/Admin đọc được metadata và có project.create theo deny > allow > Role; không hiển thị cho role thường dù backend có thể cho tạo. RPC tạo vẫn kiểm tra quyền, Lead, thuê bao và quota. Đề xuất API self-context chỉ trả role được bảo vệ và danh sách quyền hiệu lực của chính người gọi, không mở các bảng quản trị.
3. **Quá hạn đầy đủ**: RLS module độc lập với project.view. Người thường chỉ nhận badge từ các hoạt động họ đọc được; thẻ Quá hạn hiển thị — kèm chú thích, không giả định 0. Đề xuất RPC tổng hợp chỉ trả boolean/count cho Project được xem, không lộ chi tiết module.
4. **Tên người phụ trách/khách hàng**: users và leads có RLS riêng. Khi không đọc được, tên để —/không tham gia tìm kiếm; không lấy tên qua service role. Đề xuất RPC trả thông tin hiển thị tối thiểu nếu nghiệp vụ cho phép. Hiện không bảo đảm tìm khách hàng xuyên mọi Project mà người gọi chỉ có project.view.
5. **Lịch sử thống kê**: đang tính từ created_at/completed_date và trạng thái hiện tại. Không tái tạo snapshot lịch sử của dự án từng hoàn thành rồi bị đảo nghiệm thu. Cần chốt semantics và nguồn lịch sử nếu yêu cầu chỉ số lịch sử bất biến.
6. **Quy mô/concurrency**: tải toàn bộ các trang API trong phạm vi RLS (không còn giới hạn 500 dòng), sau đó lọc/phân trang phía client. Các request không cùng snapshot; ghi đồng thời có thể làm sai lệch kết quả trong lần tải. Đề xuất RPC danh sách/thống kê với bộ lọc, count, thứ tự ổn định và index company/created_at/id cho quy mô lớn, sau duyệt. Chưa benchmark dữ liệu lớn.
7. Export hiện xuất dữ liệu có project.view; không tự áp report.export (chưa có project.export và nghiệp vụ chưa quy định quyền xuất riêng cho danh sách). Nếu cần quyền riêng phải chốt trước.

Các đề xuất trên chưa được áp dụng. Không có migration mới trong lượt này.

## Kiểm thử đã chạy

- `npm ci`: đạt, 0 vulnerabilities sau retry quyền cache Windows.
- `npm run check`: đạt sau bật Docker; đủ 10 migration khớp hash.
- `npm run local:start`: đạt, chỉ project_saas_local.
- `npm run db:reset`: đạt.
- `npm run db:lint`: không lỗi schema public/app_private.
- `npm run db:test`: 6 file, 176/176 pgTAP PASS. Giữ authenticated + JWT trong test nghiệp vụ.
- `npm run app:check`: syntax check 3 file JS PASS. Repo không có framework build hoặc ESLint; không gọi đây là build/lint frontend.
- `npm run app:test`: 6/6 PASS (thứ tự timestamp/UUID, scope hidden, tìm kiếm kết hợp/ngày timezone, trạng thái quá hạn, kỳ so sánh, nội dung XLSX).
- `node scripts/test-project-browser.mjs`: Edge headless với Supabase thật PASS: Owner login/tạo từ Lead/ẩn/bỏ ẩn; Sales không thấy dự án ẩn/nút ẩn; 51 dòng với trang 20/50, đổi lọc về trang 1; tải XLSX sau tìm kiếm; không pageerror.
- Kiểm tra 1536×1024, 1366×768, 1280×800: đủ 11 cột trong DOM, không tràn ngang document; ảnh đã xem trực tiếp tại 1536 và 1366. Bảng 1366 cuộn ngang riêng; 1536 hiển thị đủ.
- File XLSX mẫu mở lại bằng openpyxl thành công; tên `=SUM(1,2) Nội thất & <test>` giữ nguyên kiểu string. Chưa mở bằng Microsoft Excel desktop.

Không chạy lại 1058 test HTTP/concurrency cũ trong lượt UI này. Chưa UI-test override allow/deny cho từng Role, đổi quyền giữa các request, keyboard focus trap dialog, nhiều tab/session và request race. Không tuyên bố production-ready hoặc hoàn tất các giới hạn backend ở trên.

## Chạy lại và bước tiếp theo

Test browser cần database local trống, tự tạo fixture qua script demo và tạo 48 Project bổ sung qua JWT Owner. Từ chối nếu DB đã có company; không tự reset. Đặt PLAYWRIGHT_MODULE thành file URL tới module Playwright hoặc cài runtime Playwright được cung cấp; cần Edge. Chạy sau reset có chủ ý trên project test này. Credentials giữ trong bộ nhớ, không ghi file/log.

Bước tiếp theo: duyệt API self-context, tổng hợp quá hạn, loại công trình và thông tin tên tối thiểu; sau đó mới bổ sung migration được duyệt, nối UI và mở rộng kiểm thử Role/tenant/export. Dữ liệu test của lượt này sẽ được reset về DB trống; dùng `npm run app:demo -- --local-only` để tạo lại tài khoản local và xem giao diện bằng `npm run app:start`.
